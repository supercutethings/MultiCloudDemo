# Copy to backend.hcl (git-ignored). Create these once, by hand or with infra/bootstrap:
#   az group create -n showcase-tfstate -l westeurope
#   az storage account create -n showcasetfstate -g showcase-tfstate --sku Standard_LRS \
#     --encryption-services blob --min-tls-version TLS1_2 --allow-blob-public-access false
#   az storage container create -n tfstate --account-name showcasetfstate --auth-mode login
resource_group_name  = "showcase-tfstate"
storage_account_name = "showcasetfstate"
container_name       = "tfstate"
