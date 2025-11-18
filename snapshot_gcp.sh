#!/usr/bin/env bash
# snapshot_gcp.sh
# Flexible GCP snapshotter with:
#  - servers list support (project/zone/instance; zone/instance; instance)
#  - optional per-line retention override
#  - labels: activity, backup-type, storage-type, created-by, retention-days
#  - snapshot name format: <servername>-<DD-MM-YYYY-HHMMSS>-<backup|clone>
#  - retention cleanup (uses per-snapshot retention-days label when present)
#
set -euo pipefail
IFS=$'\n\t'

# Defaults
RETENTION_DAYS=30
LABELS=""
PROJECT=""
SERVERS_FILE=""
DRY_RUN=false
ACTIVITY=""
BACKUP_TYPE="incremental"   # allowed: incremental|full|clone
STORAGE_LOCATION=""         # optional, e.g., "asia-south1"
CREATED_BY="auto-snapshot"

usage(){
  cat <<EOF
Usage: $0 --servers-file <file> [--project <project>] [--labels key=val,...] [--retention-days N]
          [--activity "reason"] [--backup-type incremental|full|clone] [--storage-location REGION] [--dry-run]

 servers-file line formats (per-line override allowed as 4th field):
   project,zone,instance[,retentionDays]
   zone,instance[,retentionDays]          (project taken from --project or gcloud config)
   instance[,retentionDays]               (zone auto-resolved if unique)

 Examples:
   snap-proj,asia-south1-b,web-01,7
   asia-south1-b,db-01
   web-03,14

Notes:
 - Snapshot names created: <servername>-<DD-MM-YYYY-HHMMSS>-<backup|clone> (sanitized)
 - GCP snapshots are incremental by default. --backup-type full will be labeled 'full' but GCP still stores snapshots incrementally.
 - Use --storage-location to specify snapshot storage location (if supported in your org).
EOF
  exit 1
}

# parse args
while [[ $# -gt 0 ]]; do
  case "$1" in
    --servers-file) SERVERS_FILE="$2"; shift 2;;
    --project) PROJECT="$2"; shift 2;;
    --labels) LABELS="$2"; shift 2;;
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

# label arg builder (includes our bookkeeping labels)
# accepts optional extra labels string added later (e.g., per-snapshot retention)
build_label_arg(){
  local extra_labels="$1"  # optional, may be empty
  local labels="$LABELS"
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

# describe instance (returns JSON or prints gcloud error to stderr)
describe_instance(){
  local inst="$1"; local proj="$2"; local zone="$3"
  gcloud compute instances describe "$inst" --project "$proj" --zone "$zone" --format=json 2>&1
}

# sanitize snapshot name to GCP rules
sanitize_snapshot_name(){
  local raw="$1"
  local s=$(echo "$raw" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9-]/-/g' | sed -E 's/^-+//;s/-+$//')
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
  line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
  [[ -z "$line" || "${line:0:1}" == "#" ]] && continue

  IFS=',' read -ra parts <<< "$line"
  perline_retention=""
  if [[ ${#parts[@]} -ge 3 ]]; then
    # project,zone,instance[,retention]
    if [[ ${#parts[@]} -ge 4 ]]; then
      perline_retention=$(echo "${parts[3]}" | tr -d ' ')
    fi
    project="${parts[0]}"
    zone="${parts[1]}"
    inst="${parts[2]}"
  elif [[ ${#parts[@]} -eq 2 ]]; then
    # zone,instance[,retention]
    project="$PROJECT"
    zone="${parts[0]}"
    inst="${parts[1]}"
  else
    # instance[,retention]
    project="$PROJECT"
    inst="${parts[0]}"
    # find zone if unique
    zones_found=$(gcloud compute instances list --project "$project" --filter="name=($inst)" --format="value(zone.basename())" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
    if [[ -z "$zones_found" ]]; then
      log "ERROR: Could not find instance '$inst' in project '$project'. Skipping."
      continue
    fi
    IFS=',' read -ra zarr <<< "$zones_found"
    if [[ ${#zarr[@]} -ne 1 ]]; then
      log "ERROR: Instance name '$inst' is not unique across zones: $zones_found. Provide zone explicitly. Skipping."
      continue
    fi
    zone=${zarr[0]}
  fi

  # decide retention for this instance
  if [[ -n "$perline_retention" && "$perline_retention" =~ ^[0-9]+$ ]]; then
    retention_days="$perline_retention"
  else
    retention_days="$RETENTION_DAYS"
  fi

  log "Processing: project=$project zone=$zone instance=$inst retention=${retention_days}d"

  inst_json=$(describe_instance "$inst" "$project" "$zone") || {
    log "ERROR: Failed to describe instance $inst in $zone. gcloud output:"
    echo "$inst_json"
    log "Skipping."
    continue
  }

  # extract disks
  disk_names=$(echo "$inst_json" | jq -r '.disks[]?.source' 2>/dev/null | sed -E 's|.*/||' || true)
  if [[ -z "$disk_names" ]]; then
    log "WARNING: No disks found for $inst. Skipping."
    continue
  fi

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
    desc="Snapshot of disk ${disk} from ${inst} taken at ${ts} (type=${BACKUP_TYPE})"
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
