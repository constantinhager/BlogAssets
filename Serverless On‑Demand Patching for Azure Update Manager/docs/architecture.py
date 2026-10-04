"""
Architecture diagram for AzureUpdateManagerAutomation (official Azure icons, no Mermaid).

The icons are the Microsoft Azure architecture icons as bundled in the 'diagrams' package.
The layout is hand-placed SVG on a fixed grid, rendered to PNG with headless Chromium (Playwright).

    pip install diagrams playwright
    python -m playwright install chromium
    python architecture.py          # writes architecture.svg + architecture.png

Layout
    Top lane    : runtime - callers left, Azure subscription right
                  rows inside the resource group: Function App / storage / network
                  the platform column (Resource Graph, maintenance configs, Update Manager)
                  is aligned with the row each arrow targets, so no arrow crosses a node
    Bottom lane : deployment - Entra ID + GitHub (repo -> Actions -> Terraform)
"""
import base64
import os
import pathlib

import diagrams

HERE = pathlib.Path(__file__).parent
RES = pathlib.Path(os.path.dirname(diagrams.__file__)).parent / "resources"

W, H = 1760, 1260
FONT = "Inter, 'Segoe UI', Helvetica, Arial, sans-serif"
BLUE, GREEN, PURPLE, ORANGE, GREY = "#0078D4", "#107C10", "#6E40C9", "#CA5010", "#605E5C"
INK, MUTED = "#201F1E", "#605E5C"

parts: list[str] = []


def esc(text: str) -> str:
    return text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def img(path: str) -> str:
    data = base64.b64encode((RES / path).read_bytes()).decode()
    return f"data:image/png;base64,{data}"


def text(x, y, value, size=12, weight=400, color=INK, anchor="middle", halo=False, rotate=0):
    halo_attr = ' paint-order="stroke" stroke="#FFFFFF" stroke-width="5" stroke-linejoin="round"' if halo else ""
    rot_attr = f' transform="rotate({rotate} {x} {y})"' if rotate else ""
    parts.append(f'<text x="{x}" y="{y}" font-size="{size}" font-weight="{weight}" fill="{color}" '
                 f'text-anchor="{anchor}"{halo_attr}{rot_attr}>{esc(value)}</text>')


def box(x, y, w, h, title, stroke, fill, dash=None, title_color=None, title_x=16):
    d = f' stroke-dasharray="{dash}"' if dash else ""
    parts.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="12" fill="{fill}" stroke="{stroke}" stroke-width="1.5"{d}/>')
    text(x + title_x, y + 25, title, size=13.5, weight=600, color=title_color or stroke, anchor="start")


def node(cx, cy, icon, label, size=64, badge=None):
    parts.append(f'<image href="{img(icon)}" x="{cx - size / 2}" y="{cy - size / 2}" width="{size}" height="{size}"/>')
    if badge:
        parts.append(f'<image href="{img(badge)}" x="{cx + size / 2 - 20}" y="{cy + size / 2 - 24}" width="30" height="30"/>')
    for i, line in enumerate(label.split("\n")):
        if i == 0:
            text(cx, cy + size / 2 + 19, line, size=13, weight=600, color=INK)
        else:
            text(cx, cy + size / 2 + 19 + i * 16, line, size=11.5, color=MUTED)


MARKERS = {BLUE: "aBlue", GREEN: "aGreen", PURPLE: "aPurple", ORANGE: "aOrange", GREY: "aGrey"}


def edge(points, color, label=None, label_at=None, dashed=False, width=2, anchor="middle"):
    d = "M " + " L ".join(f"{x} {y}" for x, y in points)
    dash = ' stroke-dasharray="7 5"' if dashed else ""
    parts.append(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{width}"{dash} '
                 f'marker-end="url(#{MARKERS[color]})" stroke-linejoin="round" stroke-linecap="round"/>')
    if label:
        lx, ly = label_at
        for i, line in enumerate(label.split("\n")):
            text(lx, ly + i * 15, line, size=12, weight=600, color=color, anchor=anchor, halo=True)


def step(cx, cy, n, color):
    parts.append(f'<circle cx="{cx}" cy="{cy}" r="11" fill="{color}" stroke="#FFFFFF" stroke-width="2"/>')
    text(cx, cy + 4.5, str(n), size=12, weight=700, color="#FFFFFF")


# ================================================================= header + legend
text(30, 46, "Azure Update Manager automation - Azure Function + ARM REST API", size=24, weight=700, anchor="start")
text(30, 72, "(1) find tagged machines  ·  (2) read KB exclusions  ·  (3) start assessment / one-time update  ·  (4) manage maintenance configurations",
     size=13.5, color=MUTED, anchor="start")

legend = [(BLUE, "API calls", False), (GREEN, "patching", False), (ORANGE, "data", False),
          (PURPLE, "deployment", False), (GREY, "network / RDP", False)]
lx = 1105
for color, label, dashed in legend:
    parts.append(f'<line x1="{lx}" y1="54" x2="{lx + 26}" y2="54" stroke="{color}" stroke-width="3" stroke-linecap="round"/>')
    text(lx + 33, 58, label, size=12, color=INK, anchor="start")
    lx += 40 + len(label) * 7 + 18

# ================================================================= containers
box(350, 95, 1380, 890, "Azure subscription", BLUE, "#F3F9FD")
box(380, 135, 680, 820, "rg-aum-automation", BLUE, "#FFFFFF")
box(410, 175, 620, 180, "Flex Consumption plan (FC1) - Linux", "#B58A00", "#FFFBEA")
box(410, 405, 440, 200, "Storage account", PURPLE, "#F8F5FD", title_x=150)
box(410, 645, 620, 290, "VNet vnet-aum / snet-vm - VM has no public IP", GREEN, "#F2FAF2")
box(1100, 135, 300, 820, "Azure platform (ARM REST APIs)", GREY, "#FFFFFF", dash="6 4", title_color="#323130")
box(1540, 175, 170, 215, "rg-aum-tfstate", BLUE, "#FFFFFF")

box(30, 1010, 290, 225, "Microsoft Entra ID", "#323130", "#F3F2F1")
box(350, 1010, 780, 225, "GitHub", "#57606A", "#F6F8FA")

# ================================================================= nodes: people
node(165, 260, "onprem/client/users.png", "API caller\nscript, Logic App, ITSM")
node(165, 720, "onprem/client/user.png", "Admin\nRDP client")

# ================================================================= nodes: resource group
node(520, 260, "azure/compute/function-apps.png",
     "Function App - PowerShell 7.6\nPSModuleDevelopment template\nsystem-assigned Managed Identity",
     badge="azure/identity/managed-identities.png")

node(520, 495, "azure/storage/table-storage.png", "Table: UpdateExclusions\nPK: Global | TagValue, RK: KB")
node(730, 495, "azure/storage/storage-accounts.png", "Blob: app-package\nFlex deployment package")
node(950, 495, "azure/monitor/application-insights.png", "Application Insights\n+ Log Analytics")

node(520, 720, "azure/networking/load-balancers.png", "Public Load Balancer\nStandard, public frontend IP\ninbound NAT rule -> 3389")
node(520, 855, "azure/networking/nat.png", "NAT gateway\noutbound for Windows Update")
node(890, 775, "azure/compute/virtual-machine.png", "vm-aum-01\nWindows Server 2025\nUpdateGroup = Wave1")

# ================================================================= nodes: platform + others
node(1250, 260, "azure/managementgovernance/resource-graph-explorer.png", "Azure Resource Graph\nmachines by tag\n+ assessment results")
node(1250, 495, "azure/compute/maintenance-configuration.png", "Maintenance configurations\nInGuestPatch schedules\n+ dynamic scopes")
node(1250, 775, "azure/other/update-management-center.png", "Azure Update Manager\nassessPatches\ninstallPatches")
node(1490, 775, "azure/managementgovernance/arc-machines.png", "Arc-enabled servers\n(optional)")
node(1625, 270, "azure/storage/storage-accounts.png", "Terraform state\nEntra ID auth only")

# ================================================================= nodes: deployment lane
node(175, 1125, "azure/identity/app-registrations.png", "App registration\nfederated credentials")
node(480, 1125, "onprem/vcs/github.png", "Repository\ninfra/ + function-app/")
node(740, 1125, "onprem/ci/github-actions.png", "GitHub Actions\nplan - apply - deploy")
node(1000, 1125, "onprem/iac/terraform.png", "Terraform\nazurerm, remote state")

# ================================================================= runtime edges
# API caller -> Function App
edge([(203, 260), (484, 260)], BLUE, "HTTPS + function key", (272, 249), width=2.6)

# 1 Resource Graph (straight, row 1)
edge([(556, 248), (1214, 248)], BLUE, "find machines by tag (KQL)", (900, 238))
step(598, 248, 1, BLUE)

# 2 exclusion table (short, straight down)
edge([(520, 350), (520, 459)], ORANGE)
text(540, 382, "read excluded KBs", size=12, weight=600, color=ORANGE, anchor="start", halo=True)
text(540, 397, "Storage Table Data Reader", size=11.5, color=ORANGE, anchor="start", halo=True)
step(520, 380, 2, ORANGE)

# 3 + 4 corridor between resource group and platform column
edge([(556, 272), (1080, 272), (1080, 775), (1214, 775)], BLUE, width=2.6)
edge([(1080, 495), (1214, 495)], BLUE)
text(1147, 482, "create / list", size=12, weight=600, color=BLUE, halo=True)
text(1147, 762, "assess / install", size=12, weight=600, color=BLUE, halo=True)
step(598, 272, 3, BLUE)
step(1080, 640, 4, BLUE)

# Update Manager -> machines
edge([(1214, 792), (924, 792)], GREEN, "patch run", (1015, 782), width=2.6)
edge([(1286, 775), (1454, 775)], GREEN, "patch run", (1370, 765))
edge([(1250, 612), (1250, 735)], GREEN, dashed=True)
text(1262, 668, "runs on schedule", size=12, weight=600, color=GREEN, anchor="start", halo=True)
text(1262, 683, "(dynamic scope by tag)", size=11.5, color=GREEN, anchor="start", halo=True)

# RDP path: admin -> load balancer -> NSG -> VM
edge([(201, 720), (484, 720)], GREY, "RDP (public frontend IP)", (268, 709))
edge([(556, 720), (690, 720), (690, 762), (854, 762)], GREY, "NAT rule", (623, 709))
parts.append(f'<image href="{img("azure/networking/network-security-groups.png")}" x="752" y="746" width="30" height="30"/>')
text(767, 740, "NSG: allowed CIDRs", size=11, weight=600, color=GREY, halo=True)

# outbound: VM -> NAT gateway
edge([(854, 790), (690, 790), (690, 855), (556, 855)], GREY, "outbound", (623, 845), dashed=True)

# ================================================================= deployment edges
edge([(516, 1125), (704, 1125)], PURPLE)
edge([(776, 1125), (964, 1125)], PURPLE)
edge([(722, 1091), (722, 1060), (175, 1060), (175, 1089)], PURPLE, "OIDC token - no secret", (600, 1051), dashed=True)
# zip deploy: GitHub Actions (Azure/functions-action) -> Function App.
# Flex Consumption stores the package in the app-package blob container.
# Runs up the left margin of the subscription and hops over the RDP line.
parts.append('<path d="M 758 1091 L 758 997 L 365 997 L 365 729 A 9 9 0 0 0 365 711 L 365 285 L 482 285" fill="none" '
             f'stroke="{PURPLE}" stroke-width="2" marker-end="url(#aPurple)" stroke-linejoin="round" stroke-linecap="round"/>')
text(370, 560, "zip deploy - Azure/functions-action", size=12, weight=600, color=PURPLE, halo=True, rotate=-90)
edge([(1000, 1091), (1000, 958)], PURPLE)
text(1012, 975, "provision", size=12, weight=600, color=PURPLE, anchor="start", halo=True)
edge([(1036, 1135), (1625, 1135), (1625, 393)], PURPLE, "terraform state (azurerm backend, OIDC)", (1380, 1125), dashed=True)

# ================================================================= render
markers = "".join(
    f'<marker id="{mid}" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">'
    f'<path d="M 0 0 L 10 5 L 0 10 z" fill="{col}"/></marker>'
    for col, mid in MARKERS.items()
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
