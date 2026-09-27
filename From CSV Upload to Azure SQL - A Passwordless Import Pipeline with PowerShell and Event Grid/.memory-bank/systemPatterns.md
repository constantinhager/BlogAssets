# System patterns

- Deployment and setup scripts use comment-based help blocks at script scope for operator guidance.
- Azure provisioning scripts favor idempotent create-or-reuse behavior.
- PowerShell script comment-based help should stay before any #Requires lines, and every declared parameter should have a matching .PARAMETER section.
- Helper functions in operator-facing scripts should use structured multi-line param blocks and local comment-based help when they encapsulate non-trivial behavior.
- In this repository, helper-function comment-based help may live inside the function body immediately before attributes and the param block when that is the chosen local style.
- Flex Function Apps that authenticate to their host storage with a system-assigned identity can have a first-apply ordering risk when the required storage RBAC is granted only after the app resource is created.
- Architecture documentation for this repository can be delivered as standalone SVG assets under infra/ when a real image is preferred over Mermaid.
