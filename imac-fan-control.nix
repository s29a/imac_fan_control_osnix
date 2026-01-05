{ lib, pkgs, config, ... }:

with lib;

let
  cfg = config.services.imacFanControl;

  script = pkgs.writeShellScriptBin "imac-fan-control" ''
    set -euo pipefail

    APPLESMC="/sys/devices/platform/applesmc.768"
    STATE_DIR="/run/imac-fan-control"
    FAIL_LIMIT=3
    mkdir -p "$STATE_DIR"

    log() { echo "[imac-fan] $*"; }

    cleanup() {
      for f in ${concatStringsSep " " (map (f: f.fan) (attrValues cfg.fans))}; do
        echo 0 > "$APPLESMC/${f}_manual" 2>/dev/null || true
      done
    }
    trap cleanup EXIT INT TERM

    # ---------- helpers ----------

    abs() { echo $(( $1 < 0 ? -$1 : $1 )); }

    calc_speed() {
      local t=$1 min_t=$2 max_t=$3 min_r=$4 max_r=$5
      if [ "$t" -le "$min_t" ]; then echo "$min_r"
      elif [ "$t" -ge "$max_t" ]; then echo "$max_r"
      else
        echo $(( (t - min_t) * (max_r - min_r) / (max_t - min_t) + min_r ))
      fi
    }

    # ---------- sensor discovery ----------

    find_cpu_sensor() {
      for d in /sys/class/hwmon/hwmon*; do
        [ "$(cat "$d/name" 2>/dev/null)" = "coretemp" ] && echo "$d/temp1_input" && return
      done
      return 1
    }

    find_case_sensor() {
      grep -l -E 'TA0P|TC0P|TB0T' $APPLESMC/temp*_label 2>/dev/null \
        | head -n1 | sed 's/_label/_input/'
    }

    read_temp() {
      local path="$1"
      local v
      v=$(cat "$path" 2>/dev/null) || return 1
      echo $((v / 1000))
    }

    # ---------- hysteresis ----------

    state_file() { echo "$STATE_DIR/$1.last"; }

    should_update() {
      local key="$1" temp="$2" up="$3" down="$4"
      local last

      last=$(cat "$(state_file "$key")" 2>/dev/null || echo "")
      [ -z "$last" ] && echo "$temp" > "$(state_file "$key")" && return 0

      delta=$(( temp - last ))

      if [ "$delta" -ge 0 ]; then
        [ "$delta" -ge "$up" ] || return 1
      else
        [ "$(abs "$delta")" -ge "$down" ] || return 1
      fi

      echo "$temp" > "$(state_file "$key")"
      return 0
    }

    # ---------- main loop ----------

    fail_count=0
    log "daemon started"

    while true; do
      ok=1

      # GPU
      GPU_T=$(${cfg.nvidiaSmi} --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null || ok=0)

      CPU_SENSOR=$(find_cpu_sensor || true)
      CASE_SENSOR=$(find_case_sensor || true)

      [ -n "$CPU_SENSOR" ] || ok=0
      [ -n "$CASE_SENSOR" ] || ok=0

      if [ "$ok" -eq 1 ]; then
        CPU_T=$(read_temp "$CPU_SENSOR" || ok=0)
        CASE_T=$(read_temp "$CASE_SENSOR" || ok=0)
      fi

      if [ "$ok" -eq 0 ]; then
        fail_count=$((fail_count + 1))
        if [ "$fail_count" -ge "$FAIL_LIMIT" ]; then
          log "sensor failure → AUTO"
          cleanup
        fi
        sleep ${toString cfg.interval}
        continue
      fi

      fail_count=0

      # ---------- apply fans ----------

      ${concatStringsSep "\n" (mapAttrsToList (name: f: ''
        FAN="${f.fan}"
        ROLE="${f.role}"

        if [ "$ROLE" = "gpu" ]; then
          T="$GPU_T"
        elif [ "$ROLE" = "cpu" ]; then
          T="$CPU_T"
        else
          T="$CASE_T"
        fi

        if [ "$T" -ge ${toString cfg.panicTemp} ]; then
          echo 1 > "$APPLESMC/${f.fan}_manual"
          echo "${toString f.maxRpm}" > "$APPLESMC/${f.fan}_output"
        else
          RPM=$(calc_speed "$T" ${toString f.minTemp} ${toString f.maxTemp} ${toString f.minRpm} ${toString f.maxRpm})

          if should_update "${name}" "$T" ${toString f.hysteresisUp} ${toString f.hysteresisDown}; then
            echo 1 > "$APPLESMC/${f.fan}_manual"
            echo "$RPM" > "$APPLESMC/${f.fan}_output"
          fi
        fi
      '') cfg.fans)}

      sleep ${toString cfg.interval}
    done
  '';
in
{
  options.services.imacFanControl = {
    enable = mkEnableOption "iMac advanced fan control";

    interval = mkOption {
      type = types.int;
      default = 5;
    };

    panicTemp = mkOption {
      type = types.int;
      default = 90;
    };

    nvidiaSmi = mkOption {
      type = types.path;
      default = "${config.hardware.nvidia.package}/bin/nvidia-smi";
    };

    fans = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          fan = mkOption { type = types.str; };
          role = mkOption { type = types.enum [ "cpu" "gpu" "case" ]; };

          minTemp = mkOption { type = types.int; };
          maxTemp = mkOption { type = types.int; };
          minRpm  = mkOption { type = types.int; };
          maxRpm  = mkOption { type = types.int; };

          hysteresisUp = mkOption {
            type = types.int;
            default = 1;
          };

          hysteresisDown = mkOption {
            type = types.int;
            default = 3;
          };
        };
      });
    };
  };

  config = mkIf cfg.enable {
    systemd.services.imac-fan-control = {
      description = "iMac Fan Control (auto + asymmetric hysteresis)";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${script}/bin/imac-fan-control";
        Restart = "always";
        RestartSec = 2;
        User = "root";
      };
    };
  };
}
