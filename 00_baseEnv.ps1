# 변수 정의
$rgName = "02_sqlRG"
$adminName = "labAdmin"
$adminPwd = "Demo@pass123" | ConvertTo-SecureString -asPlainText -Force
$domainName = "contoso.com"
$location = "koreacentral"
$vnetName = "sql-vnet"
$subnetName = "vmSubnet"
$saName = "jhwoowitness"
$s2dAvSetName  = "s2dSqlAvSet"
$pfsAvSetName  = "pfsSqlAvSet"
$agAvSetName   = "agSqlAvSet"
$shdAvSetName   = "shdSqlAvSet"
$s2dIlbName = "s2dILB"
$s2dIlbVIP  = "10.2.0.110"
$pfsIlbName = "pfsILB"
$pfsIlbVIP  = "10.2.0.120"
$agIlbName  = "agILB"
$agIlbVIP   = "10.2.0.130"


# 리소스 그룹 생성
$rg = New-AzResourceGroup -Name $rgName -Location $location

# 가상 네트워크 생성
New-AzResourceGroupDeployment -Name "vnet" `
    -ResourceGroupName $rgName `
    -TemplateUri "https://raw.githubusercontent.com/313mlclub/sql/main/baseEnv/01_deployVNet.json" `
    -vnetName $vnetName `
    -subnetName $subnetName

# Windows Active Directory 배포
$dcDeployment = New-AzResourceGroupDeployment -Name "DC" `
                    -ResourceGroupName $rgName `
                    -TemplateUri "https://raw.githubusercontent.com/313mlclub/sql/main/baseEnv/02_deployAD.json" `
                    -envPrefix "lab" `
                    -vmName "DC" `
                    -genericVmSize "Standard_D2s_v3" `
                    -adminUserName $adminName `
                    -adminPassword $adminPwd `
                    -domainName $domainName `
                    -vnetName $vnetName `
                    -subnetName $subnetName
                    
$vnet = Get-AzVirtualNetwork -Name $vnetName -ResourceGroupName $rgName
$vnet.DhcpOptions.DnsServers = $dcDeployment.Outputs.dcPrivateIp.Value
$vnet | Set-AzVirtualNetwork

Restart-AzVm -Name "lab-DC" -resourceGroupName $rgName 

# 클러스터를 위한 ILB 생성
foreach($ilbName in $s2dIlbName, $pfsIlbName, $agIlbName) {
    # SQL Cluster IP, SQL FCI 혹은 AG 수신기에서 사용
    switch ($ilbName) {
        $s2dIlbName { $sqlIp = $s2dIlbVIP }
        $pfsIlbName { $sqlIp = $pfsIlbVIP }
        $agIlbName  { $sqlIp = $agIlbVIP }
    }

    $sqlPort = '1433'                             # SQL Cluster IP 포트
    $sqlProbePort = '59990'                       # SQL Cluster IP 프로브 포트

    $lbProbeNamePrefix ="$($ilbName)-PROBE"              # 로드 밸런서 프로브 이름 
    $lbConfigRuleNamePrefix = "$($ilbName)-RULE"         # 로드 밸런서 규칙 이름

    $feConfigurationPrefix = "$($ilbName)-FE"            # 프런트 엔드 구성 이름
    $beConfigurationPrefix ="$($ilbName)-BEPOOL"         # 백 엔드 구성 이름

    # 초기 구성으로 로드 밸런서 생성
    $subnet = Get-AzVirtualNetworkSubnetConfig -VirtualNetwork $vnet `
                -Name $subnetName

    $feConfig = New-AzLoadBalancerFrontendIpConfig -Name "$($feConfigurationPrefix)0" `
                    -PrivateIpAddress $sqlIp `
                    -Subnet $subnet

    $beConfig = New-AzLoadBalancerBackendAddressPoolConfig -Name "$($beConfigurationPrefix)0"

    $sqlHealthProbe = New-AzLoadBalancerProbeConfig -Name "$($lbProbeNamePrefix)0" `
                            -Protocol tcp `
                            -Port $sqlProbePort `
                            -IntervalInSeconds 5 `
                            -ProbeCount 2

    $ilbRule1 = New-AzLoadBalancerRuleConfig -Name "$($lbConfigRuleNamePrefix)-SQL" `
                    -FrontendIpConfiguration $feConfig `
                    -BackendAddressPool $beConfig `
                    -Probe $sqlHealthProbe `
                    -Protocol tcp `
                    -FrontendPort $sqlPort `
                    -BackendPort $sqlPort `
                    -LoadDistribution Default `
                    -EnableFloatingIP `
                    -IdleTimeoutInMinutes 4

    $ilbRule2 = New-AzLoadBalancerRuleConfig -Name "$($lbConfigRuleNamePrefix)-NETBIOS" `
                    -FrontendIpConfiguration $feConfig `
                    -BackendAddressPool $beConfig `
                    -Probe $sqlHealthProbe `
                    -Protocol tcp `
                    -FrontendPort 445 `
                    -BackendPort 445 `
                    -LoadDistribution Default `
                    -EnableFloatingIP `
                    -IdleTimeoutInMinutes 4

    $ilbRule3 = New-AzLoadBalancerRuleConfig -Name "$($lbConfigRuleNamePrefix)-BROWSER" `
                    -FrontendIpConfiguration $feConfig `
                    -BackendAddressPool $beConfig `
                    -Probe $sqlHealthProbe `
                    -Protocol udp `
                    -FrontendPort 1434 `
                    -BackendPort 1434 `
                    -LoadDistribution Default `
                    -EnableFloatingIP `
                    -IdleTimeoutInMinutes 4 

    $ilb = New-AzLoadBalancer -Location $location `
            -Name $ilbName `
            -ResourceGroupName $rgName `
            -FrontendIpConfiguration $feConfig `
            -BackendAddressPool $beConfig `
            -LoadBalancingRule $ilbRule1, $ilbRule2, $ilbRule3 `
            -Probe $sqlHealthProbe `
            -Sku Standard

}
                        

# witness 용 스토리지 계정 생성
$sa = New-AzStorageAccount -ResourceGroupName $rgName `
        -Name $saName `
        -SkuName "Standard_LRS" `
        -Kind "Storage" `
        -Location $location

$key1 = ($sa | Get-AzStorageAccountKey).Value[0]
Write-Host "Storage account name: $($sa.StorageAccountName)"
Write-Host "Storage account key1: $key1"