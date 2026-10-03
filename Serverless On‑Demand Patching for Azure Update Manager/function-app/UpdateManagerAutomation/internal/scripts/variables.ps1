# Module-wide settings. Loaded once on import (see UpdateManagerAutomation.psm1).

# API versions in one place, so they can be bumped without touching any logic.
$script:ApiVersion = @{
	Compute       = '2024-07-01'   # Microsoft.Compute/virtualMachines assessPatches / installPatches
	HybridCompute = '2024-07-10'   # Microsoft.HybridCompute/machines assessPatches / installPatches
	Maintenance   = '2023-04-01'   # Microsoft.Maintenance maintenanceConfigurations / configurationAssignments
	ResourceGraph = '2022-10-01'   # Microsoft.ResourceGraph/resources
	TableService  = '2020-12-06'   # Minimum x-ms-version for Entra ID (OAuth) auth against Table Storage
}

$script:ArmEndpoint = 'https://management.azure.com'

# Token cache: resource -> @{ Token; ExpiresOn }
$script:TokenCache = @{}
