#set the name of the resources. 
#the keyvault and ACR names need to be globally unique, you may want to change them and make sure they are unique
export RG='cosign-rg'
export KVNAME='cosigndemokv'
export ACRNAME='cosigndemoacr'

#create resource group
az group create -n $RG --location eastus
#create container registry
az acr create -n $ACRNAME -g $RG --sku Basic
export ACRHOST=$(az acr show -g $RG -n $ACRNAME --query "loginServer" -o tsv)
#create keyvault
az keyvault create -n $KVNAME -g $RG --location eastus --enable-rbac-authorization true
#get the resource id for role assignment later
export KVID=$(az keyvault show  -n $KVNAME -g $RG --query "id" -o tsv)
export ACRID=$(az acr show -g $RG -n $ACRNAME --query "id" -o tsv)
#set subscription and tenant id
export SUBSCRIPTIONID=$(az account show --query id -o tsv)
export AZURE_TENANT_ID=$(az account show --query tenantId -o tsv)

export KVADMIN_SECRET=$(az ad sp create-for-rbac -n sp-cosign-keyadmin --role "Key Vault Crypto Officer" --scopes $KVID --query password -o tsv)
export KVADMIN_CLIENTID=$(az ad sp list --display-name sp-cosign-keyadmin --query [].appId -o tsv)
export KVSIGNER_SECRET=$(az ad sp create-for-rbac -n sp-cosign-signer --skip-assignment true --query password -o tsv)
export KVSIGNER_CLIENTID=$(az ad sp list --display-name sp-cosign-signer --query [].appId -o tsv)
export KVSIGNER_OBJID=$(az ad sp list --display-name sp-cosign-signer --query [].objectId -o tsv)
export KVREADER_SECRET=$(az ad sp create-for-rbac -n sp-cosign-reader --skip-assignment true --query password -o tsv)
export KVREADER_CLIENTID=$(az ad sp list --display-name sp-cosign-reader --query [].appId -o tsv)
export KVREADER_OBJID=$(az ad sp list --display-name sp-cosign-reader --query [].objectId -o tsv)



#set the admin credentials
export AZURE_CLIENT_ID=$KVADMIN_CLIENTID
export AZURE_CLIENT_SECRET=$KVADMIN_SECRET
#generate the keypair and store it in Key Vault
cosign generate-key-pair -kms "azurekms://$KVNAME.vault.azure.net/cosignkey"

##need to give ourself access to KeyVault keys
az role assignment create --role "Key Vault Crypto Officer" --scope $KVID --assignee-object-id $(az ad signed-in-user show --query objectId -o tsv) --assignee-principal-type User
 
az keyvault key show --name cosignkey --vault-name $KVNAME

az role assignment create --role "Key Vault Crypto User" --scope "$KVID/keys/cosignkey" --assignee-object-id $KVSIGNER_OBJID --assignee-principal-type ServicePrincipal

#set the subscription id the custom role definition
sed -i "s/<subid>/$SUBSCRIPTIONID/" key-vault-verify.json 
#create the custom role
az role definition create --role-definition key-vault-verify.json
az role assignment create --role "Key Reader + Verify" --scope "$KVID/keys/cosignkey" --assignee-object-id $KVREADER_OBJID --assignee-principal-type ServicePrincipal


docker pull nginx:latest
docker tag nginx $ACRHOST/nginx:v1
az acr login -n $ACRNAME
docker push $ACRHOST/nginx:v1


export AZURE_CLIENT_ID=$KVSIGNER_CLIENTID
export AZURE_CLIENT_SECRET=$KVSIGNER_SECRET
cosign sign -key "azurekms://$KVNAME.vault.azure.net/cosignkey" $ACRHOST/nginx:v1


export AZURE_CLIENT_ID=$KVREADER_CLIENTID
export AZURE_CLIENT_SECRET=$KVREADER_SECRET
cosign verify -key "azurekms://$KVNAME.vault.azure.net/cosignkey" $ACRHOST/nginx:v1


#Give the AcrPush permissions to the sp-cosign-signer service principal.
az role assignment create --role "AcrPush" --scope $ACRID --assignee-object-id $KVSIGNER_OBJID --assignee-principal-type ServicePrincipal


##Clean up
export KVADMIN_OBJID=$(az ad sp list --display-name sp-cosign-keyadmin --query [].objectId -o tsv)
export KVSIGNER_OBJID=$(az ad sp list --display-name sp-cosign-signer --query [].objectId -o tsv)
export KVREADER_OBJID=$(az ad sp list --display-name sp-cosign-reader --query [].objectId -o tsv)

az group delete --resource-group $RG
az ad sp delete --id $KVADMIN_OBJID
az ad sp delete --id $KVSIGNER_OBJID
az ad sp delete --id $KVREADER_OBJID

#delete custom role
