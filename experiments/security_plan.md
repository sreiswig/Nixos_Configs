# Recap: Secure n8n & Multi-Tier AI Server Architecture

## 1. Technical Architecture Overview
The current goal is to resolve the n8n "Secure Cookie" error while maintaining a private, high-security environment for your Tier 1 (Brain) and Tier 2 (Worker) servers.

- **Environment:** NixOS (Declarative/Reproducible)
- **Networking:** Tailscale (WireGuard-based Private Mesh)
- **Proxy/SSL:** Caddy (Native Tailscale integration for automated TLS)
- **Security:** Tailnet Lock (Hardware-level cryptographic signing)

## 2. Implementation Checklist

### Phase 1: SSL Foundation
- [ ] **Enable Tailscale HTTPS:** Toggle "Enable HTTPS Certificates" in the Tailscale Admin Console.
- [x] **Configure NixOS Proxy:** Add Caddy to `configuration.nix` with the `permitCertUid = "caddy"` option.
- [x] **Set Environment Variables:** Update n8n settings to use `https` protocols and your `.ts.net` hostname. (Implemented in `hosts/AIServer/configuration.nix`)

### Phase 2: Security Hardening (Tailnet Lock)
- [ ] **Initialize Lock:** Run `tailscale lock init` on the Brain server.
- [ ] **Backup Secrets:** Store "Disablement Secrets" in an offline, secure location.
- [ ] **Sign Workers:** Use `tailscale lock sign` for all Tier 2 hardware nodes.

### Phase 3: Service Migration
- [ ] **Proxy Media Services:** Point Caddy virtual hosts to the internal Tailscale IPs of your Jellyfin and Immich servers.
- [ ] **Verify Firewall:** Ensure `tailscale0` is the only trusted interface for internal management traffic.

## 3. Testing & Verification Table

| Test Case | Method | Expected Result |
| :--- | :--- | :--- |
| **Secure Cookie Fix** | Access n8n via Safari/Chrome | No warning; n8n loads fully over HTTPS |
| **Private Access** | Access URL from public Wi-Fi (No VPN) | Connection times out (Hidden from public) |
| **Hardware Trust** | Add a new un-signed device | Node shows in Tailnet but cannot ping the Brain |
| **Service Proxy** | Visit `https://jellyfin.[tailnet].ts.net` | Valid SSL certificate; media accessible |

## 4. Reasoning Steps for Debugging
1. **SSL Errors:** Verify `permitCertUid` is set for Caddy to access the Tailscale socket.
2. **DNS Errors:** Ensure MagicDNS is enabled in the Tailscale dashboard.
3. **Cookie Errors:** Double-check `N8N_SECURE_COOKIE=true` is set in the environment.
