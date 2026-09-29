# Pure hostname → Nix flake-attribute resolver.
#
# Result algebra (exactly one stdout line; never an empty success):
#   ok <flake-attr>     exit 0
#   deny empty          exit 1   blank / whitespace-only input
#   deny unknown        exit 1   no alias in the table
#
# The table is the Makefile mapping that used to live inline
# (sam_nixos → sam-main, queennas → dad_nas, …). incus_cloud is
# intentionally absent: the Makefile never switched that template host.
#
# No file, network, hostname(1), env, or clock access. The caller
# passes the hostname string. Effects (reading /etc/hostname) stay
# in the Makefile.

host_flake_resolve() (
  set -f
  IFS=$(printf ' \t\n')

  h=$1
  cr=$(printf '\r')
  h=${h%"$cr"}

  while :; do
    case $h in
      [[:space:]]*) h=${h#?} ;;
      *[[:space:]]) h=${h%?} ;;
      *) break ;;
    esac
  done

  case $h in
    '') printf '%s\n' 'deny empty'; exit 1 ;;
    sam_nixos|samnixos|sam-main|sam_main) printf '%s\n' 'ok sam-main'; exit 0 ;;
    framework13) printf '%s\n' 'ok framework13'; exit 0 ;;
    AI_Server|AIServer|ai_server) printf '%s\n' 'ok AIServer'; exit 0 ;;
    queennas|dad_nas) printf '%s\n' 'ok dad_nas'; exit 0 ;;
    asus-rog-1070|asus_rog_1070) printf '%s\n' 'ok asus_rog_1070'; exit 0 ;;
    *) printf '%s\n' 'deny unknown'; exit 1 ;;
  esac
)
