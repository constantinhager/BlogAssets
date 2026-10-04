"""
Architecture diagram for AzureUpdateManagerAutomation (official Azure icons, no Mermaid).

The icons are the Microsoft Azure architecture icons as bundled in the 'diagrams' package.
The layout is hand-placed SVG, rendered to PNG with headless Chromium (Playwright).

    pip install diagrams playwright
    python architecture.py          # writes architecture.svg + architecture.png
"""
import base64
import os
import pathlib

import diagrams

HERE = pathlib.Path(__file__).parent
RES = pathlib.Path(os.path.dirname(diagrams.__file__)).parent / "resources"

W, H = 1640, 1080
FONT = "Inter, 'Segoe UI', Helvetica, Arial, sans-serif"
BLUE, GREEN, PURPLE, ORANGE, GREY = "#0078D4", "#107C10", "#6E40C9", "#CA5010", "#605E5C"

parts: list[str] = []


def img(path: str) -> str:
    data = base64.b64encode((RES / path).read_bytes()).decode()
    return f"data:image/png;base64,{data}"


def box(x, y, w, h, title, stroke, fill, dash=None, title_color=None, title_x=14):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    parts.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="10" fill="{fill}" stroke="{stroke}" stroke-width="1.6"{d}/>')
    parts.append(f'<text x="{x + title_x}" y="{y + 24}" font-size="14" font-weight="600" fill="{title_color or stroke}">{title}</text>')


def node(cx, cy, icon, label, size=64, badge=None):
    parts.append(f'<image href="{img(icon)}" x="{cx - size / 2}" y="{cy - size / 2}" width="{size}" height="{size}"/>')
    if badge:
        parts.append(f'<image href="{img(badge)}" x="{cx + size / 2 - 22}" y="{cy + size / 2 - 26}" width="30" height="30"/>')
    for i, line in enumerate(label.split("\n")):
        weight = "600" if i == 0 else "400"
        size_ = 13 if i == 0 else 12
        color = "#201F1E" if i == 0 else GREY
        parts.append(f'<text x="{cx}" y="{cy + size / 2 + 18 + i * 16}" font-size="{size_}" font-weight="{weight}" fill="{color}" text-anchor="middle">{line}</text>')


def edge(points, color, label=None, label_at=None, dashed=False, width=2, anchor="middle"):
    d = "M " + " L ".join(f"{x} {y}" for x, y in points)
    dash = ' stroke-dasharray="7 5"' if dashed else ""
    marker = {BLUE: "aBlue", GREEN: "aGreen", PURPLE: "aPurple", ORANGE: "aOrange", GREY: "aGrey"}[color]
    parts.append(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{width}"{dash} marker-end="url(#{marker})" stroke-linejoin="round"/>')
    if label:
        lx, ly = label_at
        for i, line in enumerate(label.split("\n")):
            parts.append(f'<text x="{lx}" y="{ly + i * 15}" font-size="12.5" fill="{color}" font-weight="600" text-anchor="{anchor}" '
                         f'paint-order="stroke" stroke="#FFFFFF" stroke-width="4">{line}</text>')


def step(cx, cy, n, color):
    parts.append(f'<circle cx="{cx}" cy="{cy}" r="11" fill="{color}"/>')
    parts.append(f'<text x="{cx}" y="{cy + 4.5}" font-size="12.5" font-weight="700" fill="#FFFFFF" text-anchor="middle">{n}</text>')


# ---------------------------------------------------------------- clusters
box(360, 90, 1250, 840, "Azure subscription", BLUE, "#F3F9FD")
box(410, 130, 620, 770, "rg-aum-automation", BLUE, "#FFFFFF")
box(440, 170, 570, 180, "Flex Consumption plan (FC1) - Linux", "#C19C00", "#FFFBEA")
box(440, 420, 570, 180, "VNet - private subnet (no public IP on VM)", GREEN, "#F1FAF1", title_x=165)
box(440, 680, 420, 180, "Storage account", PURPLE, "#F7F4FC", title_x=150)
box(1070, 130, 300, 770, "Azure platform (ARM REST APIs)", GREY, "#FFFFFF", dash="6 4", title_color="#323130")
box(1390, 690, 200, 200, "rg-aum-tfstate", BLUE, "#FFFFFF")
box(30, 360, 300, 470, "GitHub", "#57606A", "#F6F8FA")
box(30, 870, 300, 170, "Microsoft Entra ID", "#323130", "#F3F2F1")

# ---------------------------------------------------------------- nodes
node(180, 230, "onprem/client/users.png", "Caller\nscript, Logic App, ITSM, scheduler")
node(180, 430, "onprem/vcs/github.png", "Repository\ninfra/ + function-app/")
node(180, 580, "onprem/ci/github-actions.png", "GitHub Actions\nplan - apply - deploy")
node(180, 730, "onprem/iac/terraform.png", "Terraform\nazurerm, remote state")
node(180, 945, "azure/identity/app-registrations.png", "App registration\nfederated credentials, no secret")

node(560, 250, "azure/compute/function-apps.png", "Function App (PowerShell 7.6)\nPSModuleDevelopment template\nsystem-assigned Managed Identity",
     badge="azure/identity/managed-identities.png")
parts.append(f'<rect x="470" y="455" width="170" height="90" rx="10" fill="#FFFFFF" stroke="{BLUE}" stroke-width="1.6"/>')
parts.append(f'<text x="555" y="482" font-size="13" font-weight="600" fill="{BLUE}" text-anchor="middle">Public Load Balancer</text>')
parts.append(f'<text x="555" y="500" font-size="12" fill="{GREY}" text-anchor="middle">frontend public IP</text>')
parts.append(f'<text x="555" y="518" font-size="12" fill="{GREY}" text-anchor="middle">RDP NAT 3389 -&gt; 3389</text>')
node(680, 500, "azure/networking/nat.png", "NAT gateway\noutbound for Windows Update")
node(900, 500, "azure/compute/virtual-machine.png", "vm-aum-01\nWindows Server 2025\nUpdateGroup = Wave1")
node(560, 760, "azure/storage/table-storage.png", "Table: UpdateExclusions\nPartitionKey: Global | TagValue\nRowKey: KB number")
node(770, 760, "azure/storage/storage-accounts.png", "Blob: app-package\nFunction.zip")
node(950, 760, "azure/monitor/application-insights.png", "Application Insights\n+ Log Analytics")

node(1215, 250, "azure/managementgovernance/resource-graph-explorer.png", "Azure Resource Graph\nmachines by tag\n+ assessment results")
node(1215, 500, "azure/other/update-management-center.png", "Azure Update Manager\nassessPatches\ninstallPatches")
node(1215, 760, "azure/compute/maintenance-configuration.png", "Maintenance configurations\nInGuestPatch schedules\n+ dynamic scopes")
node(1490, 500, "azure/managementgovernance/arc-machines.png", "Arc-enabled servers\n(optional)")
node(1490, 770, "azure/storage/storage-accounts.png", "Terraform state\nEntra ID auth only")

# ---------------------------------------------------------------- CI/CD edges
edge([(180, 505), (180, 543)], PURPLE)
edge([(180, 655), (180, 693)], PURPLE)
edge([(144, 580), (55, 580), (55, 945), (140, 945)], PURPLE, "OIDC token", (62, 860), dashed=True, anchor="start")
edge([(216, 572), (385, 572), (385, 275), (522, 275)], PURPLE, "zip deploy", (300, 562))
edge([(216, 722), (406, 722)], PURPLE, "provision", (310, 712))
edge([(216, 742), (345, 742), (345, 1000), (1490, 1000), (1490, 893)], PURPLE, "terraform state (azurerm backend, OIDC)", (920, 990), dashed=True)

# ---------------------------------------------------------------- runtime edges
edge([(216, 245), (522, 245)], BLUE, "HTTPS + function key", (292, 235), width=2.6)
edge([(216, 280), (340, 280), (340, 500), (470, 500)], GREY, "RDP 3389", (286, 492), dashed=True, anchor="middle")
edge([(640, 500), (780, 500), (780, 448), (900, 448), (900, 468)], GREY, "RDP", (806, 426))

# 1: Resource Graph
edge([(598, 238), (1180, 238)], BLUE, "find machines by tag (KQL)", (860, 228))
step(640, 238, 1, BLUE)
# 2: exclusion table
edge([(560, 352), (560, 724)], ORANGE, "read excluded KBs\nStorage Table Data Reader", (572, 640), anchor="start")
step(560, 385, 2, ORANGE)
# 3 + 4: corridor to Update Manager and maintenance configurations
edge([(598, 264), (1048, 264), (1048, 485), (1180, 485)], BLUE, "assess /\ninstall", (1118, 450), width=2.6)
edge([(1048, 480), (1048, 760), (1180, 760)], BLUE, "create /\nlist", (1118, 725))
step(640, 264, 3, BLUE)
step(1048, 715, 4, BLUE)

# Update Manager -> machines
edge([(1180, 515), (934, 515)], GREEN, "patch run", (985, 506), width=2.6)
edge([(1250, 500), (1455, 500)], GREEN, "patch run", (1352, 490))
edge([(1182, 735), (935, 528)], GREEN, "scheduled patching", (1122, 668), dashed=True)

parts.append(f'<text x="30" y="44" font-size="24" font-weight="700" fill="#201F1E">Azure Update Manager automation - Azure Function + ARM REST API</text>')
parts.append(f'<text x="30" y="70" font-size="14" fill="{GREY}">1 find tagged machines  -  2 read KB exclusions  -  3 start assessment / one-time update  -  4 manage maintenance configurations</text>')

markers = "".join(
    f'<marker id="{mid}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">'
    f'<path d="M 0 0 L 10 5 L 0 10 z" fill="{col}"/></marker>'
    for mid, col in [("aBlue", BLUE), ("aGreen", GREEN), ("aPurple", PURPLE), ("aOrange", ORANGE), ("aGrey", GREY)]
)
svg = (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="{FONT}">'
       f'<defs>{markers}</defs><rect width="{W}" height="{H}" fill="#FFFFFF"/>' + "".join(parts) + "</svg>")

svg_path = HERE / "architecture.svg"
svg_path.write_text(svg, encoding="utf-8")

from playwright.sync_api import sync_playwright  # noqa: E402

with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page(viewport={"width": W, "height": H}, device_scale_factor=2)
    page.goto(svg_path.resolve().as_uri())
    page.screenshot(path=str(HERE / "architecture.png"), full_page=False)
    browser.close()
print("written:", svg_path, HERE / "architecture.png")
