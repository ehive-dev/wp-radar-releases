#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
APP_NAME='wp-radar'
REPO='ehive-dev/wp-radar-releases'
UNIT="${APP_NAME}.service"
HEALTH_URL='http://127.0.0.1:3012/api/health'
TAG=''
while (( $# )); do
  case "$1" in --tag) TAG="${2:?Tag fehlt}"; shift 2;; *) echo "Unbekanntes Argument: $1" >&2; exit 2;; esac
done
[[ "$(id -u)" == 0 ]] || { echo 'Bitte als root ausführen.' >&2; exit 1; }
for tool in curl jq dpkg dpkg-deb sha256sum systemctl; do command -v "$tool" >/dev/null || { echo "Werkzeug fehlt: $tool" >&2; exit 1; }; done
[[ "$(dpkg --print-architecture)" == arm64 ]] || { echo 'Dieses Paket benötigt arm64.' >&2; exit 1; }
work="$(mktemp -d -t ehive-app-install.XXXXXX)"
finish(){ local rc=$?; trap - EXIT; rm -rf -- "$work"; exit "$rc"; }
trap finish EXIT
fetch(){ curl -fsSL --connect-timeout 10 --max-time 300 --retry 2 "$@"; }
if [[ -n "$TAG" ]]; then
  [[ "$TAG" =~ ^[A-Za-z0-9._-]+$ ]] || { echo 'Ungültiger Tag.' >&2; exit 1; }
  release="$(fetch "https://api.github.com/repos/$REPO/releases/tags/$TAG")"
else
  # These preview applications may not have a stable release yet.
  release="$(fetch "https://api.github.com/repos/$REPO/releases?per_page=30" | jq -ce '[.[] | select(.draft == false)] | ([.[] | select(.prerelease == false)][0] // .[0]) | select(. != null)')"
fi
[[ "$(jq -r '.draft' <<<"$release")" == false ]] || { echo 'Entwürfe werden nicht installiert.' >&2; exit 1; }
tag="$(jq -er '.tag_name' <<<"$release")"
version="${tag#v}"
[[ "$version" =~ ^[0-9]+(\.[0-9]+)*(-rc\.[0-9]+)?$ ]] || { echo 'Nicht unterstützte Paketversion.' >&2; exit 1; }
deb_version="${version/-rc./~rc}"
asset="${APP_NAME}_${version}_arm64.deb"
asset_url="$(jq -er --arg name "$asset" '.assets[] | select(.name == $name) | .browser_download_url' <<<"$release")"
sums_url="$(jq -er '.assets[] | select(.name == "SHA256SUMS") | .browser_download_url' <<<"$release")"
echo "Lade $APP_NAME $tag (prerelease=$(jq -r '.prerelease' <<<"$release")) ..."
fetch "$asset_url" -o "$work/$asset"
fetch "$sums_url" -o "$work/SHA256SUMS"
expected="$(awk -v name="$asset" '$2 == name {print $1}' "$work/SHA256SUMS")"
[[ "$expected" =~ ^[a-f0-9]{64}$ ]] || { echo 'Paketprüfsumme fehlt oder ist mehrdeutig.' >&2; exit 1; }
actual="$(sha256sum "$work/$asset")"; actual="${actual%% *}"
[[ "$actual" == "$expected" ]] || { echo 'Paketprüfsumme stimmt nicht.' >&2; exit 1; }
[[ "$(dpkg-deb -f "$work/$asset" Package)" == "$APP_NAME" && "$(dpkg-deb -f "$work/$asset" Version)" == "$deb_version" && "$(dpkg-deb -f "$work/$asset" Architecture)" == arm64 ]] || { echo 'Paket passt nicht zu Name, Version oder Architektur.' >&2; exit 1; }
export DEBIAN_FRONTEND=noninteractive
echo "Installiere $APP_NAME $version ..."
dpkg --force-confdef --force-confold -i "$work/$asset"
systemctl daemon-reload
systemctl enable --now "$UNIT"
systemctl restart "$UNIT"
for (( attempt=0; attempt<40; attempt++ )); do
  if curl --max-time 5 -fsS "$HEALTH_URL" >/dev/null; then echo "Installiert: $APP_NAME $version (healthy @ $HEALTH_URL)"; exit 0; fi
  sleep 1
done
echo "Healthcheck für $APP_NAME fehlgeschlagen." >&2
exit 1
