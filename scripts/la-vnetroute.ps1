$sub = if ($env:AZURE_SUBSCRIPTION_ID) { $env:AZURE_SUBSCRIPTION_ID } else { "<azure-subscription-id>" }
$rg = if ($env:AZURE_RESOURCE_GROUP) { $env:AZURE_RESOURCE_GROUP } else { "<resource-group>" }
$la = if ($env:LOGIC_APP_NAME) { $env:LOGIC_APP_NAME } else { "<logic-app-name>" }
$uri = "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Web/sites/$la/config/web?api-version=2023-12-01"
$body = '{"properties":{"vnetRouteAllEnabled":true}}'
Write-Host "PATCH..." -ForegroundColor Cyan
az rest --method patch --uri $uri --body $body --headers "Content-Type=application/json" --query "properties.vnetRouteAllEnabled" -o tsv
Write-Host "GET..." -ForegroundColor Cyan
az rest --method get --uri $uri --query "properties.vnetRouteAllEnabled" -o tsv
