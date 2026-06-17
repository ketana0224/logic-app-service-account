$sub = "571e49d7-d4d6-4cb5-884f-2e14bfaa662c"
$rg = "rg-dir"; $la = "la-dir-m365-connector"
$uri = "https://management.azure.com/subscriptions/$sub/resourceGroups/$rg/providers/Microsoft.Web/sites/$la/config/web?api-version=2023-12-01"
$body = '{"properties":{"vnetRouteAllEnabled":true}}'
Write-Host "PATCH..." -ForegroundColor Cyan
az rest --method patch --uri $uri --body $body --headers "Content-Type=application/json" --query "properties.vnetRouteAllEnabled" -o tsv
Write-Host "GET..." -ForegroundColor Cyan
az rest --method get --uri $uri --query "properties.vnetRouteAllEnabled" -o tsv
