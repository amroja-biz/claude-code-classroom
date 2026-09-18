#!/usr/bin/env bash
# Instance sizing, derived from cohort size. Sourced by scripts/workshop.
#
# There is no "default cohort size" anywhere in this project on purpose. Size is
# an input; the instance type falls out of it. Baking in a default would just be
# a number someone has to remember to override.
#
# The r7i family prices linearly -- checked against the AWS Pricing API on
# 2026-09-18 in us-east-1, where every size from large to 12xlarge cost $0.00827
# per GiB-hour. So there is no cost advantage to any particular size, and the
# only thing that matters is picking the smallest box the cohort fits in.
#
# These prices are INDICATIVE, not authoritative. They vary by region and change
# over time. They exist so `workshop size` can give a sense of scale; nothing
# depends on them being exact, and the memory sizing they feed is entirely
# price-independent.
#
# Why r7i and not t3: burstable CPU credits deplete when a whole cohort runs an
# exercise at the same moment, which is exactly the workshop access pattern.
#
# Memory-optimized is the default because Claude Code is mostly I/O bound. But a
# real workshop saw CPU load peak above 3.0 when participants ran scripts and
# tool installs concurrently -- those are CPU-bound and spike together. If your
# exercises execute a lot of code rather than mostly calling the model, a
# compute-optimized family may fit better: pass --instance-type to override.

# type:vCPU:GiB:USD-per-hour
LAB_INSTANCE_TABLE=(
    "r7i.large:2:16:0.1323"
    "r7i.xlarge:4:32:0.2646"
    "r7i.2xlarge:8:64:0.5292"
    "r7i.4xlarge:16:128:1.0584"
    "r7i.8xlarge:32:256:2.1168"
    "r7i.12xlarge:48:384:3.1752"
)

# Reserved for the host: OS, Docker daemon, JupyterHub container, Caddy.
LAB_HOST_OVERHEAD_GIB="${LAB_HOST_OVERHEAD_GIB:-4}"

# lab_required_gib <students> <gib-per-student>
lab_required_gib() {
    echo $(( $1 * $2 + LAB_HOST_OVERHEAD_GIB ))
}

# lab_pick_instance <students> <gib-per-student>
# Prints "type vcpu gib usd_per_hour", or exits 1 if the cohort doesn't fit.
lab_pick_instance() {
    local students="$1" per="$2" need
    need="$(lab_required_gib "$students" "$per")"

    local row type vcpu gib price
    for row in "${LAB_INSTANCE_TABLE[@]}"; do
        IFS=: read -r type vcpu gib price <<<"$row"
        if [ "$gib" -ge "$need" ]; then
            echo "$type $vcpu $gib $price"
            return 0
        fi
    done

    echo "no single instance fits ${students} students x ${per} GiB + ${LAB_HOST_OVERHEAD_GIB} GiB host = ${need} GiB." >&2
    echo "Run multiple independent stacks and encode the box in the login code (box2-blue-otter)." >&2
    return 1
}

# lab_size_report <students> <gib-per-student> <hours>
lab_size_report() {
    local students="$1" per="$2" hours="$3" picked
    picked="$(lab_pick_instance "$students" "$per")" || return 1

    local type vcpu gib price
    read -r type vcpu gib price <<<"$picked"

    # Deliberately rough. The decision this informs is "is this $3 or $300",
    # never "is this $3.18 or $3.23" -- and penny figures would imply a precision
    # that region and time both destroy.
    local disk rough
    disk="$(lab_disk_gib "$students")"
    rough="$(python3 -c "
t = $price * $hours + 0.08 * $disk / 730 * $hours + 0.005 * $hours
print('under \$1' if t < 1 else '~\$%d' % round(t))
")"

    cat <<EOF
  students          ${students}
  memory per seat   ${per} GiB  (cgroup cap per container)
  host overhead     ${LAB_HOST_OVERHEAD_GIB} GiB
  required          $(lab_required_gib "$students" "$per") GiB
  root volume       ${disk} GiB

  instance          ${type}  (${vcpu} vCPU, ${gib} GiB)
  headroom          $(( gib - $(lab_required_gib "$students" "$per") )) GiB

  cost for ${hours}h     ${rough}

  Cost is indicative only (us-east-1 on-demand, 2026-09-18).
  Check AWS pricing for your region.
EOF
}

# --- Disk -------------------------------------------------------------------
# Derived, not hardcoded. Fixed overhead measured 2026-09-18: student image
# 3.12 GB, hub image 0.61 GB, Ubuntu + Docker ~4 GB. Call it 15 GiB with room.
#
# Per-seat is 5 GiB, not the 1 GiB a fresh home suggests. A real workshop
# (geneontology/go-jupyter, ~40 participants) needed 150-200 GB of disk because
# per-user tool caches dominate -- uv/pip/npm installs a student makes during
# exercises, not the files they author. Sizing this from an empty home is the
# mistake that fills the disk mid-session.
#
# Note the one-way door: an instance cannot be launched with a root volume
# SMALLER than the AMI's snapshot, so the build volume sets the floor for every
# instance launched from that AMI. Build small.
LAB_DISK_BASE_GIB="${LAB_DISK_BASE_GIB:-15}"
LAB_DISK_PER_STUDENT_GIB="${LAB_DISK_PER_STUDENT_GIB:-5}"
LAB_DISK_MIN_GIB="${LAB_DISK_MIN_GIB:-20}"

# lab_disk_gib <students>
lab_disk_gib() {
    local gib=$(( LAB_DISK_BASE_GIB + $1 * LAB_DISK_PER_STUDENT_GIB ))
    [ "$gib" -lt "$LAB_DISK_MIN_GIB" ] && gib="$LAB_DISK_MIN_GIB"
    echo "$gib"
}
