#!/bin/bash
# power-chain — Dell power-flow chain reader (no privileges required).
#
# Sortie JSON :
#   { "source": "mains"|"typec"|"battery",
#     "usbType": "PD"|"" ...,
#     "systemW": 20.7 | null,     # puissance totale plateforme (RAPL PSYS)
#     "batteryW": +8.8 | -10.4 | null,   # + entrant (charge), - sortant
#     "componentsW": 11.9 | null, # consommation des composants (sans batterie)
#     "cpuW": 9.2 | null,         # RAPL package-0
#     "ramW": 1.1 | null,         # RAPL dram
#     "screenW": 1.6 | null }     # screen: deduced residual (components - cpu - ram)
#
# RAPL counters are cumulative energy: sampled over 1 s.

set -u

RAPL=/sys/class/powercap
BAT=/sys/class/power_supply/BAT0
UCSI=/sys/class/power_supply/ucsi-source-psy-*

rapl_energy() { # $1 = nom de domaine (psys, package-0, dram)
  local d
  for d in "$RAPL"/intel-rapl*; do
    if [[ -f $d/name && $(cat "$d/name" 2>/dev/null) == "$1" ]]; then
      cat "$d/energy_uj" 2>/dev/null
      return
    fi
  done
}

e_psys=$(rapl_energy psys) || e_psys=""
e_pkg=$(rapl_energy package-0) || e_pkg=""
e_dram=$(rapl_energy dram) || e_dram=""
e_core=$(rapl_energy core) || e_core=""
e_uncore=$(rapl_energy uncore) || e_uncore=""
v1=$(cat "$BAT/voltage_now" 2>/dev/null) || v1=""
i1=$(cat "$BAT/current_now" 2>/dev/null) || i1=""
sleep 1
f_psys=$(rapl_energy psys) || f_psys=""
f_pkg=$(rapl_energy package-0) || f_pkg=""
f_dram=$(rapl_energy dram) || f_dram=""
f_core=$(rapl_energy core) || f_core=""
f_uncore=$(rapl_energy uncore) || f_uncore=""

watts() { # $1 e1 $2 e2 -> W (µJ sur 1 s = µW)
  awk -v a="$1" -v b="$2" 'BEGIN { printf "%.1f", (b - a) / 1e6 }'
}

systemW=null
[[ -n $e_psys && -n $f_psys ]] && systemW=$(watts "$e_psys" "$f_psys")

cpuW=null
[[ -n $e_pkg && -n $f_pkg ]] && cpuW=$(watts "$e_pkg" "$f_pkg")

ramW=null
[[ -n $e_dram && -n $f_dram ]] && ramW=$(watts "$e_dram" "$f_dram")

coreW=null
[[ -n $e_core && -n $f_core ]] && coreW=$(watts "$e_core" "$f_core")

uncoreW=null
[[ -n $e_uncore && -n $f_uncore ]] && uncoreW=$(watts "$e_uncore" "$f_uncore")

igpuW=null
if [[ $cpuW != null && $coreW != null && $uncoreW != null ]]; then
  igpuW=$(awk -v p="$cpuW" -v c="$coreW" -v u="$uncoreW" \
    'BEGIN { g = p - c - u; if (g < 0) g = 0; printf "%.1f", g }')
fi

v2=$(cat "$BAT/voltage_now" 2>/dev/null) || v2=""
i2=$(cat "$BAT/current_now" 2>/dev/null) || i2=""
# -- end of sampling --

# Battery power averaged over the sampling window (V×I at both ends) so it
# stays consistent with the RAPL deltas (1 s averages).
batteryW=null
if [[ -n $v1 && -n $i1 && -n $v2 && -n $i2 ]]; then
  batteryW=$(awk -v v1="$v1" -v i1="$i1" -v v2="$v2" -v i2="$i2" \
    'BEGIN { printf "%.1f", (v1 * i1 + v2 * i2) / 2e12 }')
fi

# Design capacity when new (Wh): charge_full_design (µAh) × nominal voltage.
nominalWh=null
cfd=$(cat "$BAT/charge_full_design" 2>/dev/null) || cfd=""
vmin=$(cat "$BAT/voltage_min_design" 2>/dev/null) || vmin=""
if [[ -n $cfd && -n $vmin ]]; then
  nominalWh=$(awk -v c="$cfd" -v v="$vmin" 'BEGIN { printf "%.0f", c * v / 1e12 }')
fi

ac=$(cat /sys/class/power_supply/AC/online 2>/dev/null) || ac=0
uc=0
for f in $UCSI; do
  [[ -d $f ]] || continue
  if [[ $(cat "$f/online" 2>/dev/null) == 1 ]]; then uc=1; break; fi
done

# USB-C port: power delivered to a connected device (phone, etc.).
# Le pilote ucsi peut rapporter une tension nulle : on suppose alors 5 V.
portW=null
for f in $UCSI; do
  [[ -d $f ]] || continue
  uv=$(cat "$f/voltage_now" 2>/dev/null) || uv=""
  ui=$(cat "$f/current_now" 2>/dev/null) || ui=""
  if [[ -n $ui && $ui -gt 0 ]]; then
    [[ -z $uv || $uv -eq 0 ]] && uv=5000000
    portW=$(awk -v v="$uv" -v i="$ui" 'BEGIN { printf "%.1f", v * i / 1e12 }')
    break
  fi
done

usbType=""
if [[ $uc == 1 ]]; then
  for f in $UCSI; do
    [[ -f $f/usb_type ]] || continue
    usbType=$(tr -d '[]' < "$f/usb_type" | awk '{print $1}')
    break
  done
fi

if [[ $ac == 1 ]]; then source="mains"
elif [[ $uc == 1 ]]; then source="typec"
else source="battery"
fi

# The EC may report positive current even while discharging. Trust the
# battery STATE (not the source presence) for the sign: a weak USB-C adapter
# can leave the battery powering the laptop even while "plugged in".
bstat=$(cat "$BAT/status" 2>/dev/null) || bstat=""
discharging=false
[[ $bstat == "Discharging" ]] && discharging=true

if $discharging && [[ $batteryW != null ]]; then
  batteryW=$(awk -v w="$batteryW" 'BEGIN { if (w > 0) w = -w; printf "%.1f", w }')
fi

componentsW=null
adapterW=null
if [[ $batteryW != null ]]; then
  if $discharging; then
    # The battery is supplying. psys measures the platform draw, so the
    # adapter's contribution is whatever the battery doesn't cover.
    if [[ $systemW != null ]]; then
      componentsW=$systemW
      adapterW=$(awk -v s="$systemW" -v b="$batteryW" \
        'BEGIN { a = s + b; if (a < 0) a = 0; printf "%.1f", a }')
    else
      componentsW=$(awk -v b="$batteryW" 'BEGIN { c = -b; if (c < 0) c = 0; printf "%.1f", c }')
    fi
  elif [[ $source == "battery" ]]; then
    # On battery (not discharging per state, e.g. idle): same fallback.
    componentsW=$(awk -v b="$batteryW" 'BEGIN { c = -b; if (c < 0) c = 0; printf "%.1f", c }')
  elif [[ $systemW != null ]]; then
    # On AC, psys measures the platform ALONE (charging is not counted —
    # verified empirically). The adapter provides both.
    componentsW=$systemW
    adapterW=$(awk -v s="$systemW" -v b="$batteryW" \
      'BEGIN { c = s + (b > 0 ? b : 0); printf "%.1f", c }')
  fi
fi

screenW=null
if [[ $componentsW != null && $cpuW != null && $ramW != null ]]; then
  screenW=$(awk -v c="$componentsW" -v p="$cpuW" -v r="$ramW" \
    'BEGIN { s = c - p - r; if (s < 0) s = 0; printf "%.1f", s }')
fi

jq -n --arg s "$source" --arg t "$usbType" \
  --argjson b "$batteryW" --argjson y "$systemW" --argjson c "$componentsW" \
  --argjson a "$adapterW" \
  --argjson p "$cpuW" --argjson r "$ramW" --argjson e "$screenW" \
  --argjson g "$igpuW" --argjson n "$nominalWh" --argjson w "$portW" \
  '{source:$s, usbType:$t, batteryW:$b, systemW:$y, adapterW:$a, componentsW:$c, cpuW:$p, ramW:$r, screenW:$e, igpuW:$g, nominalWh:$n, portW:$w}'
