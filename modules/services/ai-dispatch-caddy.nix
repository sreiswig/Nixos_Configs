# AI_Dispatch home UI+API on Tailscale MagicDNS (trusted network only).
# UI binds on 127.0.0.1:8081 (Attic already owns :8080 on AIServer).
# API: https://dispatch…/api/health → http://127.0.0.1:8000/health
{ ... }: {
  services.caddy.virtualHosts."dispatch.tail93ec7d.ts.net".extraConfig = ''
    handle_path /api* {
      reverse_proxy 127.0.0.1:8000
    }

    handle {
      reverse_proxy 127.0.0.1:8081
    }
  '';
}
