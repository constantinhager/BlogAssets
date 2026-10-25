# SecretRotation - Function App

Monitors client secrets and certificates of all Entra ID app registrations, reports expiring ones by mail and
tracks them in a renewal state table. Renews a credential only when an admin sets its RenewalState to Renewable,
and stores the new credential in Azure Key Vault.

Scaffolded with the `AzureFunction` template of [PSModuleDevelopment](https://github.com/PowershellFrameworkCollective/PSModuleDevelopment).

| Function | Trigger | What it does |
|---|---|---|
| `Invoke-AppCredentialCheck` | Timer, daily 05:00 UTC | Check all apps, update the state table, mail the report - renews nothing |
| `Invoke-AppCredentialRenewalQueue` | Timer, every 15 minutes | Renew every row with RenewalState = Renewable, write the result back |
| `Get-AppCredentialReport` | HTTP GET (function key) | Read-only report of all credentials, decision and RenewalState |

Run the offline tests: `./tests/Test-SecretRotation.ps1`
Build the package: `./build/psf-build.ps1` (on Windows, see the root README)

The template instructions below are kept for reference.

## Template Instructions

### Layout

There are three folders with this project:

+ build: Where all the magic happens - do not touch, other than the config file (`build.config.psd1`)
+ function: Where the basic function app files are stored. Generally you only need to update the `requirements.psd1` for Managed Dependencies (do not use when running on Flex Consumption plan)
+ `<name>`: Folder with the PowerShell module that gets turned into a function app. This is where you add your content, usually.

### Flex Consumption and You

If you plan to deploy the function app code to an App running under the Flex Consumption plan, **you must configure the template for it!**
Not all features are available in that plan - specifically the Managed Dependencies feature does not work - and that changes the requirements we have to work with.

To make things work, open the project configuration file: `build\build.config.psd1`.
Enable the Flex Consumption behavior by setting `General > FlexConsumption` to `$true`.

### Adding your content

Your own code is usually placed in the `<name>` root level folder, which is a regular, lightweight PowerShell module structure.
Treat it as a module and add code as you would for a module.

Any RequiredModules you declare will automatically be downloaded and bundled with the function app during build.

There _is_ however one special aspect:
In the `functions` subfolder you will find several subfolders, that are special to this template:

+ `<name>/functions/eventGridTrigger`
+ `<name>/functions/httpTrigger`
+ `<name>/functions/nonPublished`
+ `<name>/functions/timerTrigger`

Functions placed in a particular trigger-folder will be published as that kind of trigger within the function app.
For example, if you place a `Get-EntraUser.ps1` file & PS-function under the `httpTrigger` subfolder, your function-app will have an http endpoint with the url `<function-app-baseurl>/api/Get-EntraUser` that accepts the same parameters (via body or query) as the PS-function you wrote.

The same applies to the other trigger kinds (though a Timer Trigger cannot receive any parameters, even if you add them to the PS-function).

> Configuring Details

Having the triggers generated automatically is all nice and useful, but some triggers might need some extra configuration.
For example, when defining a timer trigger, what is the actual schedule it triggers on?

All those configuration aspects can be found under `build/build.config.psd1`.
For each setting you can define a global default and overrides for specific, individual endpoints.
The individual settings and what they mean are documented in that file.
