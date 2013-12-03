desc="Push latest live-* branch to staging or live server"
function usage () {
cat << EOF
usage: site.sh push [live | <source>]
                    [--revert (live | staging)]

  If live is passed, crosswalk-project.org will be updated to reflect
  the version of the site currently hosted on stg.crosswalk-project.org.
  
  Otherwise, this script will push a version of the site (generated 
  with "site.sh mklive") to the staging server stg.crosswalk-project.org.
  
  If no source specified, the most recent local live-* branch name
  will be used. Otherwise the branch identified with source will
  be used.

  NOTE: source must be a branch generated by "site.sh mklive" and
  have a name in the form of live-*.  

Options:
  --revert
    The specified site will be configured to the previous version. 
    The target must be either 'live' or 'staging'. If not specified,
    'staging' will be the default.
    
    If you encounter a problem on the live server and need to quickly
    revert, you can provide the 'live' target.
  
    NOTE: There is only one level of undo. If you need to revert to an
    older version, you can perform the following:
  
    1. Find the version you want:
  
       git branch | grep live
  
    2. Push that version to the staging server:
  
       site.sh push SOURCE
     
    3. Manually verify the https://stg.crosswalk-project.org is correct.
  
    4. Push the staging server to the live server:
  
       site.sh push live
  
EOF
}

function revert () {
    case "$1" in
    ""|staging)
        target=staging
        url=https://stg.crosswalk-project.org
        ;;
    live)
        target=live
        url=https://crosswalk-project.org
        ;;
    *) 
        echo "Invalid command option: $*"
        usage
        return
        ;;
    esac

    echo -n "Fetching active branch name from ${target} server..." >&2
    active=$(get_remote_live_info --previous $target)
    echo ""

    echo -n "Fetching previous branch name from ${target} server..." >&2
    previous=$(get_remote_live_info --previous $target)
    echo ""

    if [[ ! "${previous}" =~ live-* ]]; then
        cat << EOF >&2

Error: Prior branch file not found on server:
       404 ${url}/PRIOR-REVISION
       Aborting.
       
EOF
        exit 1
    fi
    
    push "revert" ${target} ${previous} ${active}
}


# Prompt the user with information about what will be pushed to where,
# and then optionally push it.
#
function push () {
    mode=$1
    target=$2
    rev=$3
    current=$4
    git=$(git remote show -n origin | sed -ne 's,^.*Push.*URL: \(.*\)$,\1,p')
    shortsha=${rev/%???????????????????????????}
    case $target in
    live)
        url=sites1.vlan14.01.org
        site=crosswalk-project.org
        ;;
    staging)
        url=stg-sites.vlan14.01.org
        site=stg.crosswalk-project.org
        ;;
    esac

    path=/srv/www/${site}/docroot

    current_name=$(branchname ${current})
    current_sha=$(branchsha ${current}) || die "Could not find ${current_name}"
    new_name=$(branchname ${rev})
    new_sha=$(branchsha ${rev}) || die "Could not find ${new_name}"
    if [[ "${new_sha}" == "" ]]; then
        echo "SHA not found for ${new_name}"
        exit 1
    fi

    cat << EOF

About to ${mode} ${target} server:

EOF
    printf "  %-20.20s       %-20.20s\n"    "Current version" "New version"
    printf "  %-20.20s    => %-20.20s\n"    ${current_name}   ${new_name}
    printf "  %-20.20s... => %-20.20s...\n" ${current_sha} ${new_sha}
    cat << EOF
    
This will perform the following:

  1. Push ${shortsha} to:
     ${git}
     
  2. Connect to ${target} server (${url}) and run:
     a. git pull / git fetch
     b. git clean -f
     c. Update REVISION and PRIOR-REVISION
     
EOF

    if [[ "${new_sha}" == "${current_sha}" ]]; then
        cat << EOF
NOTE: No changes detected (identical SHA). Perhaps you need to run 
      "site.sh mklive" first to generate a new live image.
  
EOF
    fi

    while true; do
        echo -n "Proceed? [(Y)es|(n)o|(s)how diff|(l)og] "
        read answer
        case $answer in
        S|s)
            { git diff --exit-code ${current_sha}..${new_sha} && 
                echo "No differences." ; } | less
            ;;
        L|l)
            { git log --exit-code ${current_sha}..${new_sha} && 
                echo "No differences." ; } | less
            ;;
        ""|Y|y)
            break
            ;;
        N|n)
            return
            ;;
        esac
    done
    
    printf "Connecting to ${url} to update to %-.29s...\n" ${rev}
    # SSH to the target machine and execute the bash sequence implemented
    # in the function 'remote', passing in the branch name to switch to.
    { declare -f remote ; echo "remote ${path} ${rev}" ; } | ssh -T ${url}
    
    echo -n "Triggering History and Page regeneration..."
    echo ${site}
    wget -qO - https://${site}/regen.php
    if [ ! -e wiki/pages.md.html ] || [ ! -e wiki/history.md.html ]; then
        echo "FAILED!"
    else
        echo "done"
    fi
}

#
# remote 
# Executes on the remote server; not called locally
# Takes a single argument in the form BRANCH:SHA where BRANCH is
# in the live-* syntax
#
function remote () {
    function drush_routine () {
        branch=$1
        name=${branch/:*}
        sha=${branch/*:}
        dry_run=
        current=$(cat REVISION)
        # If the current branch name is the same as the new branch name,
        # do a git pull. Otherwise fetch the requested branch (and all 
        # necessary objects) and check it out.
        if [[ "${current/:*}" == "${name}" ]]; then
            echo -n "Running: git pull ${name}:${name}..."
            ${dry_run} git pull -q origin ${name}:${name} || die "\n'git pull' failed."
        else
            echo -n "Running: git fetch origin ${name}:${name}..."
            ${dry_run} git fetch -q origin ${name}:${name} || die "\n'git fetch' failed."
            echo "done."
            echo -n "Running: git checkout -f ${name}"
            ${dry_run} git checkout -q -f ${name} || {
                echo -e "\nError running checkout! Resetting to ${current/*:}\n\n"
                echo -e "Running: git reset --hard ${current/*:} && git clean -f\n"
                git reset --hard ${current/*:}
                exit
            }
            echo "done."
        fi
        echo "Running: git clean -f"
        ${dry_run} git clean -f
        echo "Creating PRIOR-REVISION and REVISION"
        echo $current > PRIOR-REVISION
        echo $branch > REVISION
        echo "Updated to ${branch}"
    }

    path=$1
    shift
    cd "${path}" || return
    { declare -f drush_routine ; echo drush_routine $* ; } | sudo su drush -
}

# usage: site.sh push [live | <source>]
#                     [--revert (live | staging)]
function run () {
    if [[ "$1" == "--revert" ]]; then
        shift
        revert $*
        return
    fi

    echo -n "Fetching staging branch name from stg.crosswalk-project.org..." >&2
    staging=$(get_remote_live_info staging)
    echo "done"

    if [[ "$1" == "live" ]]; then
        target="live"
        echo -n "Fetching live branch name from crosswalk-project.org..." >&2
        current=$(get_remote_live_info)
        echo "done."
        rev=${staging}
    else
        target="staging"
        current=${staging}
        if [[ "$1" == "" ]]; then
            rev=$(get_local_live_info) || 
                die "Unable to determine local info for ${rev/:*/}"
        else
            rev=$1
        fi
    fi 

    url=$(git remote show -n origin | sed -ne 's,^.*Push.*URL: \(.*\)$,\1,p')
    
    branch=$(branchname ${rev})
    echo -en "Checking for ${branch} at ${url}..."
    git remote show origin | grep -q ${branch} || {
        echo "not found."
        echo "Running: git push -u origin ${branch}:${branch}..."
        git push -u origin ${branch}:${branch}
    }
    echo "done."

    push "set" $target $rev $current
}
