# Run before an exporter of homelab.observability.scrape starts. Its
# credentials come from an environment file under /var/lib/secrets, which a
# tmpfiles rule creates empty. Until the owner fills it in, the check fails
# the start with a message naming the file and the variables it needs, so
# the unit is failed and says why, and the rest of the stack runs
# (docs/adr/0029-network-gear-scraped-through-exporters.md).
{ writeShellApplication, gnugrep }:

writeShellApplication {
  name = "scrape-secret-check";
  runtimeInputs = [ gnugrep ];
  text = ''
    # scrape-secret-check <exporter> <doc> <file> <variable>...
    exporter=$1 doc=$2 file=$3
    shift 3
    missing=()
    if [ -f "$file" ] && [ -r "$file" ]; then
      for var in "$@"; do
        grep -q "^$var=." "$file" || missing+=("$var")
      done
    else
      missing=("$@")
    fi
    if [ "''${#missing[@]}" -gt 0 ]; then
      echo "$exporter does not start: $file does not set ''${missing[*]}. Provision it as $doc says, then restart this unit; Prometheus and the rest of the stack run without it." >&2
      exit 1
    fi
  '';
}
