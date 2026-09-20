#!/usr/bin/env bash
# Instance sizing, derived from cohort size. Sourced by scripts/workshop.
#
# There is no "default cohort size" anywhere in this project on purpose. Size is
# an input; the instance type falls out of it. Baking in a default would just be
# a number someone has to remember to override.
#
# The r7i family prices linearly -- checked against the AWS Pricing API on
# 2026-09-18 in us-east-1, where every size from large to 12xlarge cost $0.00827
# per GiB-hour.
#
# That linearity is the whole argument for erring large. One size up costs
# single-digit dollars for a day of teaching; one size down costs thirty people
# their afternoon and the instructor their credibility. There is no exchange
# rate at which that trade is worth taking, so this picks the smallest box that
# clears the requirement WITH margin -- it does not try to find the cheapest
# box the cohort can be squeezed into. See PRINCIPLES.md: 2 beats 3.
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

# What one seat actually uses at peak, in MiB. THE BOX IS SIZED FROM THIS, not
# from the cap.
#
# Sizing used to be "a fixed percentage of the per-seat cap", which coupled two
# numbers that are not related. The cap is deliberately set well above real
# usage, so a percentage of it only lands in the right place while that gap
# happens to hold. Set the cap near true peak -- exactly what a careful
# operator does -- and the same formula silently picked a box the class could
# exhaust. Nothing checked it and nothing said so.
#
# Cap and box now answer their own questions:
#   cap (--mem)  "when do we kill ONE student?"   -> recoverable, one person
#   box size     "when does the HOST die?"        -> unrecoverable, everyone
#
# Measured 2026-09-20, one seat, whole container, cgroup v2 memory.peak (the
# kernel's own high-water mark -- sampling `docker stats` at 2s missed the true
# peak by 22%):
#
#   idle JupyterLab                      154 MiB
#   + Claude Code open, idle             301 MiB
#   Claude reasoning, no execution       482 MiB
#   Claude executing a toolchain build  1036 MiB   <- this figure
#
# Anon (unreclaimable) stayed at 246 MiB throughout; the rest is reclaimable
# page cache, and page cache is SHARED between seats, so N x this figure
# overstates a real cohort. Erring high is the intended direction.
#
# NOT measured: a full course, a long-lived session whose context grows until
# compaction, and any degree of concurrency. Override when you have measured
# your own material -- scripts/test-containment.sh shows how to read the number.
# Was this supplied by the operator, or is it our own figure? The difference
# decides what happens when the cap moves -- see lab_effective_peak_mib.
LAB_PEAK_MIB_SET="${LAB_PEAK_MIB:+yes}"
LAB_PEAK_MIB="${LAB_PEAK_MIB:-1024}"

# The cap our measurement was taken against. The 1024 MiB figure describes a
# seat running under a 2 GiB cap; it is not a universal constant.
LAB_MEASURED_AT_CAP_GIB="${LAB_MEASURED_AT_CAP_GIB:-2}"

# lab_effective_peak_mib <cap-gib>
# What to size from, given the cap in force.
#
# Raising --mem is an operator saying "my seats need more than the default".
# Sizing from a measurement taken against the DEFAULT cap would silently ignore
# that and hand them the same box -- the measurement simply does not describe
# their material. But planning at the cap for everyone would throw away a real
# measurement and double the default box for no reason.
#
# So: trust a measurement when there is one, use ours while the cap it was
# taken against still holds, and otherwise fall back to the only safe
# assumption available -- that a seat may use what the cap allows it to.
lab_effective_peak_mib() {
    local cap_gib="$1"
    if [ -n "$LAB_PEAK_MIB_SET" ]; then
        echo "$LAB_PEAK_MIB"                      # operator measured their own
    elif [ "$cap_gib" = "$LAB_MEASURED_AT_CAP_GIB" ]; then
        echo "$LAB_PEAK_MIB"                      # our measurement still applies
    else
        echo $(( cap_gib * 1024 ))                # no measurement: plan at the cap
    fi
}

# An instance advertised as 64 GiB does not give the OS 64 GiB -- firmware and
# the kernel reserve a few percent. Comparing against the nominal figure is how
# a cohort that "exactly fits" fails to fit on the actual box.
LAB_USABLE_PERCENT="${LAB_USABLE_PERCENT:-95}"

# Slack required on top of the plan. Without it the picker will happily choose a
# box where usable memory equals the requirement to the gigabyte, which leaves
# nothing for the planning assumptions themselves being a little wrong.
LAB_HEADROOM_PERCENT="${LAB_HEADROOM_PERCENT:-10}"

# lab_required_gib <students> <peak-mib-per-student>
# What we provision for: every seat at its MEASURED peak simultaneously, plus
# the host's own needs.
#
# Full concurrency is deliberate and is not the discredited "cap x N" mistake.
# A taught class runs the same step at the same moment -- thirty people hit the
# heavy cell inside the same half-minute -- so for the peak of a given exercise
# the concurrency factor really is ~1. What was wrong before was applying that
# to the inflated CAP; applying it to measured usage is just honest.
lab_required_gib() {
    echo $(( ($1 * $2 + 1023) / 1024 + LAB_HOST_OVERHEAD_GIB ))
}

# lab_usable_gib <nominal-gib>
lab_usable_gib() {
    echo $(( $1 * LAB_USABLE_PERCENT / 100 ))
}

# lab_pick_instance <students> [peak-mib-per-student]
# Prints "type vcpu gib usd_per_hour", or exits 1 if the cohort doesn't fit.
lab_pick_instance() {
    local students="$1" per="${2:-$LAB_PEAK_MIB}" need
    need="$(lab_required_gib "$students" "$per")"

    local row type vcpu gib price
    for row in "${LAB_INSTANCE_TABLE[@]}"; do
        IFS=: read -r type vcpu gib price <<<"$row"
        if [ $(( $(lab_usable_gib "$gib") * 100 )) -ge $(( need * (100 + LAB_HEADROOM_PERCENT) )) ]; then
            echo "$type $vcpu $gib $price"
            return 0
        fi
    done

    echo "no single instance fits ${students} students: ${need} GiB needed (${per} MiB measured peak x ${students} + ${LAB_HOST_OVERHEAD_GIB} GiB host)." >&2
    echo "Run multiple independent stacks and encode the box in the login code (box2-blue-otter)." >&2
    return 1
}

# lab_size_report <students> <gib-per-seat-cap> <hours>
# The cap is reported, not used to size. Sizing comes from LAB_PEAK_MIB.
lab_size_report() {
    local students="$1" cap="$2" hours="$3" picked peak basis
    peak="$(lab_effective_peak_mib "$cap")"
    if [ -n "$LAB_PEAK_MIB_SET" ]; then
        basis="measured by you (LAB_PEAK_MIB)"
    elif [ "$cap" = "$LAB_MEASURED_AT_CAP_GIB" ]; then
        basis="measured at the default ${cap} GiB cap"
    else
        basis="the cap itself -- no measurement for a ${cap} GiB cap"
    fi
    picked="$(lab_pick_instance "$students" "$peak")" || return 1

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

    local need usable capsum oversub
    need="$(lab_required_gib "$students" "$peak")"
    usable="$(lab_usable_gib "$gib")"
    # If every seat pegged its cap at once. This is EXPECTED to exceed usable
    # memory -- caps are ceilings and the cohort is deliberately oversubscribed
    # against them. It is printed because the previous formula left exactly
    # this fact unstated, and silent oversubscription is what PRINCIPLES rules
    # out. Seeing "3.0x" is normal; seeing it is the point.
    capsum=$(( students * cap ))
    oversub="$(python3 -c "
r = $capsum / max($usable, 1)
print('%.1fx usable memory -- expected; caps are ceilings' % r if r >= 1.0
      else 'fits usable memory even if every seat pegged its cap')")"

    cat <<EOF
  students          ${students}
  sized from        ${peak} MiB   per seat, whole container
  basis             ${basis}
  host overhead     ${LAB_HOST_OVERHEAD_GIB} GiB      OS, Docker, JupyterHub, Caddy
  required          ${need} GiB     every seat at peak, at the same moment

  per-seat cap      ${cap} GiB      a container is OOM-killed above this
  if all capped     ${capsum} GiB     ${oversub}

  instance          ${type}  (${vcpu} vCPU, ${gib} GiB nominal)
  usable memory     ${usable} GiB     nominal less $(( 100 - LAB_USABLE_PERCENT ))% firmware/kernel reserve
  headroom          $(( usable - need )) GiB

  root volume       ${disk} GiB    destroyed at 'down'
  cost for ${hours}h       ${rough}

  Why this one: the smallest r7i whose usable memory clears ${need} GiB with
  ${LAB_HEADROOM_PERCENT}% to spare. Sized from measured peak usage, not from the cap -- the
  cap is deliberately well above real usage, so sizing from it tracked a
  number chosen for a different purpose.

  The cap is what still protects the class: one runaway agent is killed in its
  own cgroup, not on the host. Disk, CPU and process count are capped per seat
  too -- see scripts/test-containment.sh, which proves all four every run.

  To change it:  --instance-type <type>     pick the box yourself
                 --mem <GiB>                change the per-seat cap
                 LAB_PEAK_MIB=<MiB>         after measuring YOUR material

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
