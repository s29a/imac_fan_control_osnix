{ lib, pkgs, config, ... }:

with lib;

let
  cfg = config.services.imacFanControl;

  # Подготовка путей для Bash-ассоциативного массива
  sensorsInitBash = concatStringsSep "\n" (mapAttrsToList (name: path: ''
    SENSOR_PATHS["${name}"]="${path}"
  '') cfg.sensors);

  script = pkgs.writeShellScriptBin "imac-fan-control" ''
    set -u

    APPLESMC="/sys/devices/platform/applesmc.768"
    STATE_DIR="/run/imac-fan-control"
    mkdir -p "$STATE_DIR"

    declare -A SENSOR_PATHS
    declare -A CURRENT_TEMPS
    ${sensorsInitBash}

    log() { echo "[imac-fan] $*"; }

    # Функция поиска пути по коду SMC (например, Tp2H -> temp21_input)
    find_smc_path() {
      local code="$1"
      grep -l "$code" "$APPLESMC"/temp*_label 2>/dev/null | sed 's/_label/_input/' | head -n1
    }

    # Возврат к автоматическому управлению при выходе
    cleanup() {
      log "Cleaning up: returning fans to AUTO mode..."
      for f in ${concatStringsSep " " (unique (map (f: f.fan) (attrValues cfg.fans)))}; do
        if [ -w "$APPLESMC/''${f}_manual" ]; then
           echo 0 > "$APPLESMC/''${f}_manual" 2>/dev/null || true
        fi
      done
      exit 0
    }
    trap cleanup EXIT INT TERM

    # Математика управления
    abs() { echo $(( $1 < 0 ? -$1 : $1 )); }
    
    calc_speed() {
      local t=$1 min_t=$2 max_t=$3 min_r=$4 max_r=$5
      if [ "$min_t" -ge "$max_t" ]; then echo "$max_r"; return; fi
      if [ "$t" -le "$min_t" ]; then echo "$min_r"; return; fi
      if [ "$t" -ge "$max_t" ]; then echo "$max_r"; return; fi
      # Линейная интерполяция: (t - min_t) / (max_t - min_t) * (max_r - min_r) + min_r
      echo $(( (t - min_t) * (max_r - min_r) / (max_t - min_t) + min_r ))
    }

    # Чтение температуры без лишних процессов
    read_temp() {
      local val
      if [ -r "$1" ]; then
        read -r val < "$1" 2>/dev/null || return 1
        echo $((val / 1000))
      else return 1; fi
    }

    # --- Инициализация датчиков ---
    log "Initializing sensors for iMac 12,2..."
    for name in "''${!SENSOR_PATHS[@]}"; do
      path="''${SENSOR_PATHS[$name]}"

      if [[ "$path" == "CORETEMP" ]]; then
        actual=$(grep -l "coretemp" /sys/class/hwmon/hwmon*/name | sed 's/name/temp1_input/' | head -n1)
        if [ -n "$actual" ]; then
          SENSOR_PATHS["$name"]="$actual"
          log "Auto-discovered CPU coretemp at $actual"
        else
          log "CRITICAL: coretemp driver not found in /sys/class/hwmon/"
          exit 1
        fi

      elif [[ "$path" == SMC:* ]]; then
        code=''${path#SMC:}
        actual=$(find_smc_path "$code")
        if [ -z "$actual" ]; then
          log "CRITICAL: Sensor $code (for $name) NOT FOUND in AppleSMC!"
          exit 1
        fi
        SENSOR_PATHS["$name"]="$actual"
        log "Mapped $name ($code) to $actual"
      fi
    done

    # --- Hysteresis Logic ---
    state_file() { echo "$STATE_DIR/$1.last"; }
    should_update() {
      local key="$1" temp="$2" up="$3" down="$4"
      local file=$(state_file "$key")
      if [ ! -f "$file" ]; then echo "$temp" > "$file"; return 0; fi
      read -r last < "$file"
      local delta=$(( temp - last ))
      if [ "$delta" -ge 0 ]; then
        [ "$delta" -ge "$up" ] || return 1
      else
        [ "$(abs "$delta")" -ge "$down" ] || return 1
      fi
      echo "$temp" > "$file"
      return 0
    }

    # --- Main Loop ---
    fail_count=0
    while true; do
      loop_ok=1
      # 1. Опрос всех датчиков
      for name in "''${!SENSOR_PATHS[@]}"; do
        path="''${SENSOR_PATHS[$name]}"
        if [ "$path" = "nvidia-auto" ]; then
          val=$(${cfg.nvidiaSmi} --query-gpu=temperature.gpu --format=csv,noheader,nounits 2>/dev/null) || loop_ok=0
        else
          val=$(read_temp "$path") || loop_ok=0
        fi
        CURRENT_TEMPS["$name"]=''${val:-0}
      done

      if [ "$loop_ok" -eq 0 ]; then
        fail_count=$((fail_count + 1))
        [ "$fail_count" -ge 3 ] && cleanup
        sleep ${toString cfg.interval}; continue
      fi
      fail_count=0

      # 2. Управление вентиляторами
      ${concatStringsSep "\n" (mapAttrsToList (fname: f: ''
        MAX_T=0
        for src in ${concatStringsSep " " f.sources}; do
          t=''${CURRENT_TEMPS[$src]}
          [ "$t" -gt "$MAX_T" ] && MAX_T="$t"
        done

        FAN_ID="${f.fan}"
        if [ "$MAX_T" -ge ${toString cfg.panicTemp} ]; then
          echo 1 > "$APPLESMC/''${FAN_ID}_manual"
          echo "${toString f.maxRpm}" > "$APPLESMC/''${FAN_ID}_output"
        else
          TARGET_RPM=$(calc_speed "$MAX_T" ${toString f.minTemp} ${toString f.maxTemp} ${toString f.minRpm} ${toString f.maxRpm})
          if should_update "${fname}" "$MAX_T" ${toString f.hysteresisUp} ${toString f.hysteresisDown}; then
            echo 1 > "$APPLESMC/''${FAN_ID}_manual"
            echo "$TARGET_RPM" > "$APPLESMC/''${FAN_ID}_output"
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
    interval = mkOption { type = types.int; default = 5; };
    panicTemp = mkOption { type = types.int; default = 90; };
    nvidiaSmi = mkOption { type = types.path; default = "${config.hardware.nvidia.package}/bin/nvidia-smi"; };

    sensors = mkOption {
      type = types.attrsOf types.str;
      example = { cpu = "SMC:TC0P"; psu = "SMC:Tp2H"; };
    };

    fans = mkOption {
      type = types.attrsOf (types.submodule {
        options = {
          fan = mkOption { type = types.str; description = "fan1, fan2, or fan3"; };
          sources = mkOption { type = types.listOf types.str; };
          minTemp = mkOption { type = types.int; };
          maxTemp = mkOption { type = types.int; };
          minRpm  = mkOption { type = types.int; };
          maxRpm  = mkOption { type = types.int; };
          hysteresisUp = mkOption { type = types.int; default = 2; };
          hysteresisDown = mkOption { type = types.int; default = 4; };
        };
      });
    };
  };

  config = mkIf cfg.enable {
    systemd.services.imac-fan-control = {
      description = "iMac 12,2 Fan Control Daemon";
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = "${script}/bin/imac-fan-control";
        Restart = "always";
        User = "root";
      };
    };
  };
}
