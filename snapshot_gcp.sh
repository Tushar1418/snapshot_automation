#!/usr/bin/env bash
# snapshot_gcp.sh
# Flexible GCP snapshotter with:
#  - servers list support (project/zone/instance; zone/instance; instance)
#  - optional per-line retention override
#  - supports treating name as VM or as disk directly
#  - tolerant of extra spaces in servers file
#  - labels: activity, backup-type, storage-type, created-by, retention-days (+ user labels/tags)
#  - snapshot name format: <servername>-<DD-MM-YYYY-HHMMSS>-<backup|clone>
#  - retention cleanup (uses per-snapshot retention-days label when present)
#
set -euo pipefail
IFS=$'\n\t'

# Defaults
RETENTION_DAYS=30
LABELS=""
TAGS=""
PROJECT=""
SERVERS_FILE=""
DRY_RUN=false
ACTIVITY=""
BACKUP_TYPE="incremental"   # allowed: incremental|full|clone
STORAGE_LOCATION=""         # optional, e.g., "asia-south1"
CREATED_BY="auto-snapshot"

usage(){
  cat <<EOF
Usage: $0 --servers-file <file> [--project <project>] [--labels key=val,...] [--tags key=val,...] [--retention-days N]
          [--activity "reason"] [--backup-type incremental|full|clone] [--storage-location REGION] [--dry-run]

 servers-file line formats (per-line override allowed as final field):
   project,zone,instance[,retentionDays]
   zone,instance[,retentionDays]
   instance[,retentionDays]

 Examples:
   snap-proj,asia-south1-b,web-01,7
   asia-south1-b,db-01
   web-03,14
   asia-south1-b,my-disk,7        # treated as disk if instance not found
   my-disk,7                      # direct disk by name (zone auto-resolved if unique)

Notes:
 - Snapshot names created: <servername>-<DD-MM-YYYY-HHMMSS>-<backup|clone> (sanitized)
 - GCP snapshots are incremental by default. --backup-type full will be labeled 'full' but GCP still stores snapshots incrementally.
 - Use --storage-location to specify snapshot storage location (if supported in your org).
 - GCP snapshots do not support "tags" like instances; --tags are applied as labels internally.
EOF
  exit 1
}

# parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --servers-file) SERVERS_FILE="$2"; shift 2;;
    --project) PROJECT="$2"; shift 2;;
    --labels) LABELS="$2"; shift 2;;
    --tags) TAGS="$2"; shift 2;;
    --retention-days) RETENTION_DAYS="$2"; shift 2;;
    --dry-run) DRY_RUN=true; shift 1;;
    --activity) ACTIVITY="$2"; shift 2;;
    --backup-type) BACKUP_TYPE="$2"; shift 2;;
    --storage-location) STORAGE_LOCATION="$2"; shift 2;;
    -h|--help) usage;;
    *) echo "Unknown arg: $1"; usage;;
  esac
done

if [[ -z "$SERVERS_FILE" ]]; then
  echo "ERROR: --servers-file required"
  usage
fi

# fallback project
if [[ -z "$PROJECT" ]]; then
  PROJECT=$(gcloud config get-value project 2>/dev/null || true)
  if [[ -z "$PROJECT" ]]; then
    echo "ERROR: project not supplied and gcloud config project is empty"
    exit 2
  fi
fi

# validate backup type
if [[ "$BACKUP_TYPE" != "incremental" && "$BACKUP_TYPE" != "full" && "$BACKUP_TYPE" != "clone" ]]; then
  echo "ERROR: --backup-type must be one of incremental|full|clone"
  exit 3
fi

echo "Project: $PROJECT"
echo "Servers file: $SERVERS_FILE"
echo "Labels: $LABELS"
echo "Tags: $TAGS"
echo "Global retention days: $RETENTION_DAYS"
echo "Activity: $ACTIVITY"
echo "Backup type: $BACKUP_TYPE"
echo "Storage location: $STORAGE_LOCATION"
echo "Dry run: $DRY_RUN"
echo

log(){ echo "[$(date -u +%FT%T%Z)] $*"; }

# run helper (safe)
run_cmd(){
  local cmd="$*"
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY RUN] $cmd"
  else
    bash -c "$cmd"
  fi
}

# describe instance (returns JSON or empty on error)
describe_instance(){
  local inst="$1"; local proj="$2"; local zone="$3"
  gcloud compute instances describe "$inst" --project "$proj" --zone "$zone" --format=json 2>/dev/null
}

# label arg builder (includes our bookkeeping labels)
# accepts optional extra labels string added later (e.g., per-snapshot retention)
build_label_arg(){
  local extra_labels="$1"  # optional, may be empty
  local labels="$LABELS"

  # user "tags" (conceptual) are implemented as labels on snapshots
  if [[ -n "$TAGS" ]]; then
    labels="${labels}${labels:+,}${TAGS}"
  fi

  labels="${labels}${labels:+,}created-by=${CREATED_BY}"
  if [[ -n "$ACTIVITY" ]]; then
    act=$(echo "$ACTIVITY" | sed 's/[^a-zA-Z0-9]/_/g' | tr '[:upper:]' '[:lower:]')
    labels="${labels},activity=${act}"
  fi
  labels="${labels},backup-type=${BACKUP_TYPE}"
  if [[ -n "$STORAGE_LOCATION" ]]; then
    labels="${labels},storage-type=${STORAGE_LOCATION}"
  fi
  if [[ -n "$extra_labels" ]]; then
    labels="${labels},${extra_labels}"
  fi
  # remove any leading/trailing commas/spaces
  labels=$(echo "$labels" | sed 's/^,*//;s/,*$//;s/ //g')
  echo "--labels=${labels}"
}

# sanitize snapshot name to GCP rules
sanitize_snapshot_name(){
  local raw="$1"
  local s
  s=$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]/-/g' | sed -E 's/^-+//;s/-+$//')
  if [[ ! "$s" =~ ^[a-z] ]]; then
    s="s-${s}"
  fi
  if [[ ${#s} -gt 63 ]]; then
    s=${s:0:63}
    s=$(echo "$s" | sed -E 's/-+$//')
    if [[ ! "$s" =~ [a-z0-9]$ ]]; then
      s="${s}0"
    fi
  fi
  echo "$s"
}

# main loop
while IFS= read -r line || [[ -n "$line" ]]; do
  # trim full line
  line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [[ -z "$line" || "${line:0:1}" == "#" ]] && continue

  # split on commas and trim each part (handles extra spacing)
  IFS=',' read -ra raw_parts <<< "$line"
  parts=()
  for p in "${raw_parts[@]}"; do
    local_trimmed=$(echo "$p" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [[ -n "$local_trimmed" ]] && parts+=("$local_trimmed")
  done

  num_parts=${#parts[@]}
  if [[ $num_parts -eq 0 ]]; then
    continue
  fi

  perline_retention=""
  project="$PROJECT"
  zone=""
  name=""

  case "$num_parts" in
    4)
      # project,zone,name,retention
      project="${parts[0]}"
      zone="${parts[1]}"
      name="${parts[2]}"
      perline_retention="${parts[3]}"
      ;;
    3)
      # could be project,zone,name OR zone,name,retention
      if [[ "${parts[2]}" =~ ^[0-9]+$ ]]; then
        # zone, name, retention
        zone="${parts[0]}"
        name="${parts[1]}"
        perline_retention="${parts[2]}"
      else
        # project, zone, name
        project="${parts[0]}"
        zone="${parts[1]}"
        name="${parts[2]}"
      fi
      ;;
    2)
      # could be zone,name OR name,retention
      if [[ "${parts[1]}" =~ ^[0-9]+$ ]]; then
        # name, retention
        name="${parts[0]}"
        perline_retention="${parts[1]}"
      else
        # zone, name
        zone="${parts[0]}"
        name="${parts[1]}"
      fi
      ;;
    1)
      # name only
      name="${parts[0]}"
      ;;
    *)
      log "ERROR: Invalid line format: $line"
      continue
      ;;
  esac

  # clean and validate retention override
  if [[ -n "$perline_retention" ]]; then
    perline_retention=$(echo "$perline_retention" | tr -d ' ')
    if ! [[ "$perline_retention" =~ ^[0-9]+$ ]]; then
      log "WARNING: Invalid retention '${perline_retention}' for '${name}', using global ${RETENTION_DAYS}d"
      perline_retention=""
    fi
  fi

  # decide retention for this entry
  if [[ -n "$perline_retention" ]]; then
    retention_days="$perline_retention"
  else
    retention_days="$RETENTION_DAYS"
  fi

  inst="$name"
  is_instance="false"
  is_direct_disk="false"

  # Try to resolve as instance first
  # If zone not known, attempt to auto-resolve instance zone
  if [[ -z "$zone" ]]; then
    zones_found=$(gcloud compute instances list --project "$project" --filter="name=($inst)" --format="value(zone.basename())" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    if [[ -n "$zones_found" ]]; then
      IFS=',' read -ra zarr <<< "$zones_found"
      if [[ ${#zarr[@]} -eq 1 ]]; then
        zone="${zarr[0]}"
      else
        log "INFO: Instance name '$inst' not unique across zones for project '$project' (zones: $zones_found). Will attempt disk matching."
        zone=""
      fi
    fi
  fi

  inst_json=""
  if [[ -n "$zone" ]]; then
    inst_json=$(describe_instance "$inst" "$project" "$zone" || true)
  fi

  if [[ -n "$inst_json" ]]; then
    is_instance="true"
  fi

  disk_names=""

  if [[ "$is_instance" == "true" ]]; then
    log "Processing instance: project=$project zone=$zone instance=$inst retention=${retention_days}d"
    disk_names=$(echo "$inst_json" | jq -r '.disks[]?.source' 2>/dev/null | sed -E 's|.*/||' || true)
    if [[ -z "$disk_names" ]]; then
      log "WARNING: No disks found for instance $inst. Skipping."
      continue
    fi
  else
    # Treat as disk name
    disk_name="$name"

    # If zone still unknown, resolve based on disk name
    if [[ -z "$zone" ]]; then
      zones_found=$(gcloud compute disks list --project "$project" --filter="name=($disk_name)" --format="value(zone.basename())" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
      if [[ -z "$zones_found" ]]; then
        log "ERROR: Could not find instance or disk named '$disk_name' in project '$project'. Skipping."
        continue
      fi
      IFS=',' read -ra zarr <<< "$zones_found"
      if [[ ${#zarr[@]} -ne 1 ]]; then
        log "ERROR: Name '$disk_name' is not unique across disk zones: $zones_found. Provide zone explicitly. Skipping."
        continue
      fi
      zone="${zarr[0]}"
    fi

    # verify disk exists
    if ! gcloud compute disks describe "$disk_name" --project "$project" --zone "$zone" >/dev/null 2>&1; then
      log "ERROR: '$disk_name' is neither a valid instance nor disk in project=$project zone=$zone. Skipping."
      continue
    fi

    log "Processing disk directly: project=$project zone=$zone disk=$disk_name retention=${retention_days}d"
    disk_names="$disk_name"
    is_direct_disk="true"
    inst="$disk_name"
  fi

  # snapshot all discovered disks
  for disk in $disk_names; do
    ts=$(date -u +"%d-%m-%Y-%H%M%S")
    type_tag="backup"
    if [[ "$BACKUP_TYPE" == "clone" ]]; then
      type_tag="clone"
    elif [[ "$BACKUP_TYPE" == "full" ]]; then
      type_tag="backup"
    fi

    if [[ "$disk" == "$inst" ]]; then
      raw_name="${inst}-${ts}-${type_tag}"
    else
      raw_name="${inst}-${disk}-${ts}-${type_tag}"
    fi

    snap_name=$(sanitize_snapshot_name "$raw_name")

    # description and labels (include per-snapshot retention label)
    if [[ "$is_direct_disk" == "true" ]]; then
      desc="Snapshot of disk ${disk} taken at ${ts} (type=${BACKUP_TYPE})"
    else
      desc="Snapshot of disk ${disk} from instance ${inst} taken at ${ts} (type=${BACKUP_TYPE})"
    fi

    extra_labels="retention-days=${retention_days}"
    labelArg=$(build_label_arg "${extra_labels}")

    # storage-location arg if provided
    storage_arg=""
    if [[ -n "$STORAGE_LOCATION" ]]; then
      storage_arg="--storage-location=${STORAGE_LOCATION}"
    fi

    cmd="gcloud compute disks snapshot ${disk} --project=${project} --zone=${zone} --snapshot-names=${snap_name} --description=\"${desc}\" ${labelArg} ${storage_arg} --quiet"
    log "Creating snapshot: ${snap_name} (disk=${disk})"
    run_cmd "$cmd" && log "Snapshot created: $snap_name" || log "ERROR: Snapshot command failed for $disk"
  done

done < "$SERVERS_FILE"

# retention cleanup: delete snapshots older than their per-snapshot retention-days label (fallback to global)
log "Running retention cleanup (project=${PROJECT})"

# fetch snapshots that match our "created-by" label
filter="labels.created-by=${CREATED_BY}"
gcloud compute snapshots list --project="$PROJECT" --filter="$filter" --format=json 2>/dev/null | \
  jq -r '.[] | "\(.name) \(.creationTimestamp) \((.labels["retention-days"] // ""))"' | \
  while IFS=' ' read -r name creationTs retentionLabel; do
    # name validation: ensure it follows our pattern (safety)
    if [[ ! "$name" =~ (backup|clone)$ ]]; then
      continue
    fi
    created_epoch=$(date -d "$creationTs" +%s)
    if [[ -n "$retentionLabel" && "$retentionLabel" =~ ^[0-9]+$ ]]; then
      cutoff_for_snap=$(date -d "${retentionLabel} days ago" +%s)
    else
      cutoff_for_snap=$(date -d "${RETENTION_DAYS} days ago" +%s)
    fi
    if [[ $created_epoch -lt $cutoff_for_snap ]]; then
      log "Deleting snapshot $name created at $creationTs (retention=${retentionLabel:-$RETENTION_DAYS}d)"
      run_cmd "gcloud compute snapshots delete ${name} --project=${PROJECT} --quiet"
    fi
  done

log "Snapshot process completed."
