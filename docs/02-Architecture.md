# Architecture Overview

Logic App + Service Account 方式の全体ネットワーク・セキュリティアーキテクチャ。

## ネットワークダイアグラム

```
┌─────────────────────────────────────────────────────────────────┐
│                      Internet Backbone                          │
│                 login.microsoftonline.com                       │
│               graph.microsoft.com (Microsoft Graph)             │
└────────────────────────┬──────────────────────────────────────┘
                         │ HTTPS:443 (AFW許可)
                         │
                    ┌────▼─────┐
                    │    AFW    │
                    │ 10.0.3.4  │
                    └────┬──────┘
                         │ 内部 VNet
                         │
            ┌────────────┼────────────┐
            │                         │
       ┌────▼──────────┐      ┌──────▼────────┐
       │  snet-logicapp      │   snet-pep    │
       │  10.0.1.0/27  │      │ 10.0.2.0/27   │
       │                │      │                │
       │ ┌──────────────┐      │ ┌───────────┐ │
       │ │ Logic App LA ├──PE──┼─┤ PE 10.0.2 │ │
       │ │ (Standard)   │      │ │ (sites)   │ │
       │ └──────────────┘      │ │           │ │
       │                │      │ ├─ KV PE    │ │
       │ (VNet Integ)  │      │ │ 10.0.2.8  │ │
       │                │      │ ├─ St PE    │ │
       │                │      │ │ file/b/q/t│ │
       │                │      │ └───────────┘ │
       │                │      │                │
       └───┬────────────┘      └────────────────┘
           │ (PE only, no public)
           │
           ├─→ Key Vault (PE)         ┌─────────────────┐
           │   kv-dirm365-3647        │ Private DNS     │
           │   (secrets encrypted)    │ Zones           │
           │                          │ ────────────────│
           └─→ Storage Account (PE)   │ privatelink.    │
               (host state)           │  azurewebsites  │
                                      │  .vault...      │
                                      │  .blob...       │
                                      └─────────────────┘
```

## VNet Design

| Subnet | CIDR | 用途 | 備考 |
|---|---|---|---|
| `snet-logicapp` | 10.0.1.0/27 | Logic App Standard | VNet integration |
| `snet-pep` | 10.0.2.0/27 | Private Endpoints | 6 PE をホスト |
| `AzureFirewallSubnet` | 10.0.3.0/26 | Azure Firewall | 必須 (AFW は /26 以上) |
| `snet-jumpbox` | 10.0.4.0/27 | Jumpbox VM (Test) | 踏み台、運用補助のみ |

## Private Link Configuration

### Private Endpoints (6 個)

| # | リソース | PE 名 | IP | Service |
|---|---|---|---|---|
| 1 | Logic App | `pe-la-dir` | 10.0.2.9 | sites |
| 2 | Key Vault | `pe-kv-dir` | 10.0.2.8 | vault |
| 3 | Storage (file) | `pe-st-file` | 10.0.2.7 | file |
| 4 | Storage (blob) | `pe-st-blob` | 10.0.2.4 | blob |
| 5 | Storage (queue) | `pe-st-queue` | 10.0.2.5 | queue |
| 6 | Storage (table) | `pe-st-table` | 10.0.2.6 | table |

### Private DNS Zones (linked to vnet-dir)

| # | DNS Zone | 用途 |
|---|---|---|
| 1 | `privatelink.azurewebsites.net` | Logic App PE 名前解決 |
| 2 | `privatelink.vaultcore.azure.net` | Key Vault PE |
| 3 | `privatelink.file.core.windows.net` | Storage file PE |
| 4 | `privatelink.blob.core.windows.net` | Storage blob PE |
| 5 | `privatelink.queue.core.windows.net` | Storage queue PE |
| 6 | `privatelink.table.core.windows.net` | Storage table PE |

## Outbound Firewall Rules

### Azure Firewall Policy: afwp-dir

**Source**: snet-logicapp (10.0.1.0/27)

#### 必須ルール (OAuth / Microsoft Graph)

| # | Type | Destination | Protocol | Port | Priority | Action |
|---|---|---|---|---|---|---|
| 1 | Application | `login.microsoftonline.com` | HTTPS | 443 | 100 | Allow |
| 2 | Application | `graph.microsoft.com` | HTTPS | 443 | 101 | Allow |
| 3 | Network | `AzureActiveDirectory` (service tag) | TCP | 443 | 102 | Allow |

#### 将来削除候補ルール (最小化時)

| # | Type | Destination | 理由 |
|---|---|---|---|
| 4 | Application | `*.azurewebsites.net` | Logic App `scm` (PE 化時削除) |
| 5 | Application | `management.azure.com` | ARM API (運用用、不要時削除) |
| 6 | Network | `AzureMonitor` | Log Analytics (AMPLS 構成時削除) |
| 7 | Application | `*.vaultcore.azure.net` | KV PE フォールバック (削除可) |
| 8 | Network | `Storage.WestUS2` | Storage PE フォールバック (削除可) |

## セキュリティ層

### Layer 1: Network Access

| 境界 | 制御 | 状態 |
|---|---|---|
| Inbound Public | `publicNetworkAccess=Disabled` | ✅ Closed |
| Inbound PE | Private Endpoint | ✅ Limited |
| Outbound | Azure Firewall + UDR | ✅ Whitelist FQDN |

### Layer 2: Authentication

| 対象 | 方式 | 保管 |
|---|---|---|
| Logic App ← Key Vault | Managed Identity (SAMI) | MSI token in memory |
| Logic App ← Microsoft 365 | OAuth Access Token (1h) | Memory (in-flight only) |
| refresh_token | Secret in Key Vault | Encrypted at rest (FIPS 140-2) |

### Layer 3: Data Encryption

| データ | 転送中 | 保管時 |
|---|---|---|
| Logic App ← PE | TLS 1.2+ | — |
| Key Vault Secret | TLS 1.2+ | AES-256 (FIPS) |
| Storage (host state) | TLS 1.2+ | Storage Service Encryption |

### Layer 4: RBAC

| Identity | Resource | Role | Scope |
|---|---|---|---|
| Logic App SAMI | Key Vault | **Key Vault Secrets Officer** | Secret GET/SET |
| (M365) admin | Service Account | (Delegated permission) | User sign-in / token grant |

## DNS Resolution Path

### Private Endpoint 経由 (VNet 内)

```
Logic App internal query
  ↓
Private DNS Zone resolver
  ↓
Resolves to PE IP (e.g., 10.0.2.9)
  ↓
Connection within VNet (no Internet routing)
```

例: `la-dir-m365-connector.azurewebsites.net` → `10.0.2.9`

### Fallback (Edge case: PE DNS 失敗時、AFW 経由で public DNS resolve)

```
Internal DNS cache miss
  ↓
AFW を通って public DNS query (unusual)
  ↓
Public resolution
  ↓
AFW で FQDN フィルタリング確認
  ↓
허용된 FQDN のみ通過 (그 외 blocked)
```

## Route Table Configuration

### rt-snet-logicapp

Associated with: **snet-logicapp** (10.0.1.0/27)

| Destination | Next Hop | Action |
|---|---|---|
| `0.0.0.0/0` | `10.0.3.4` (AFW) | Route all outbound to firewall |
| `10.0.0.0/16` | `VNetLocal` | Keep VNet traffic local (system) |

**効果**: Logic App の全 outbound が Azure Firewall を通る → 明示的な FQDN whitelist でのみ Internet 到達可能

## Conditional Access Considerations

Service Account (`system-notify@...`) が登場する場合の Microsoft Entra CA ポリシー設定：

| CA Policy | 推奨設定 | 理由 |
|---|---|---|
| **Sign-in Frequency** | SA を除外グループに追加 | 24h / 7d policy で refresh_token が失効 |
| **Risk-based Sign-in** | SA を除外 | Risk event で MFA prompt / Block → refresh失敗 |
| **MFA Requirement** | SA を除外 | MFA は dialog prompt → refresh_token 非対話失敗 |
| **Compliant Device** | SA を除外 | Device object がない |
| **Hybrid AD Join** | SA を除外 | SA はクラウドのみ |

設定例:
```
Policy: "Require MFA for sensitive operations"
Include Users: All except [grp-automation-accounts]
  └─ [system-notify@...] member of grp-automation-accounts
```

## Cost Optimization Points

### Network

- **VNet Peering** (不要): Single VNet で足りる
- **Express Route** (不要): Firewall + UDR で足りる
- **WAF** (不要): AFW Standard で十分
- **DDoS Protection** (オプション): Standard (VNet linked) = ~$2,944/月

### Compute

- **VM 使用**: Jumpbox のみ、Auto-Shutdown で最小化
- **Logic App Plan**: WS1 は 1 vCPU × 3.5GB で固定課金

### Storage

- **Data Transfer**: Firewall / 踏み台 VM を経由するため追加あり
- **Archive Tier**: Logic App host state は Hot tier (Low cost already)

---

**参照**: [docs/01-Design.md](01-Design.md) / [README.md](../README.md)
