#!/usr/bin/env bash
# Thunderbird Backup Tool

shopt -s expand_aliases
set -o pipefail
#set -e

EGG_VERSION='1.1.0'
MULTIPLEX_TERM=true
SCREEN_LAYER=0
VERBOSE_LOG=false
LOG_TO_FILE=false # sets LOG_FILE
ISO_TIMESTAMP=false
EXECUTE_AFTER=false
DEFAULT_TBIRD_DIR="$HOME/.thunderbird"
SOURCE_PATH=''
DEST_PATH=''
PROFILE_NAME=''
DEFAULT_ALIAS_RULES_FILE='alias_rules.json'

BACKUP_TARGETS=(
    'cert9.db'
    'cert_override.txt'
    'key4.db'
    'encrypted-openpgp-passphrase.txt'
    'handlers.json'
    'logins.json'
    'openpgp.sqlite'
    'permissions.sqlite'
    'prefs.js'
    'pubring.gpg'
    'secring.gpg'
    # Profiles must be backed up each time their folder trees are modified.
    # Uncomment the line below to backup the folder tree.
    #'folderTree.json'
)

# shellcheck disable=SC2034
CMAP_MOON=('🌑' '🌒' '🌓' '🌔' '🌕' '🌖' '🌗' '🌘')

R='\e[31m'; G='\e[32m'; Y='\e[33m'
B='\e[34m'; M='\e[35m'; C='\e[36m'
X='\e[0m'; #E='\e[1m'

alias '@inl'='_LOG_INLINE=1'
alias '@nop'='_LOG_NOPRE=1'

log.init() {
    local color="$1"; shift
    local prefix="$1"; shift
    [ -n "$_LOG_NOPRE" ] && prefix=''
    local message="${color}${prefix}${*}${X}"
    local opts='-e'
    [ -n "$_LOG_INLINE" ] && opts+='n'
    echo "$opts" "$message" | tee -a "$LOG_FILE"
}
log.echo()  { log.init '' '' "${*}"; }
log.info()  { log.init "${B}" '❖ ' "${*}${X}"; }
log.info2() { log.init "${C}" '❖ ' "${*}${X}"; }
log.info3() { log.init "${M}" '❖ ' "${*}${X}"; }
log.ok()    { log.init "${G}" '✔ ' "${*}${X}"; }
log.warn()  { log.init "${Y}" '✖ ' "${*}${X}"; }
log.error() { log.init "${R}" '✖ ' "${*}${X}"; }
log.fatal() { log.init "${R}" '✖ ' "${*}${X}"; exit 1; }

time.epoch() { date -u +%s; }
time.datetime() { date -u +'%FT%T'; }

loader() {
    local text='LOADING <spinner>'
    # shellcheck disable=SC1003
    local default_spinner=('-' '\' '|' '/')
    local spinner=("${default_spinner[@]}")
    # Default spinner speed is ONE iteration per second
    local loop=3
    local gap

    while (( $# > 0 )) ; do
        case "$1" in
            -t|--text)
                text="$2"
                shift 2 ;;
            -s|--spinner)
                if [[ "$2" =~ ^[a-zA-Z0-9\_]+$ ]] ; then
                    declare -n _spinner="${2}"
                    if (( ${#_spinner[@]} < 1 )) ; then
                        echo -e '\e[33mWarn: Loader: Empty spinner array provided\e[0m'
                    else
                        spinner=("${_spinner[@]}")
                    fi
                    unset _spinner
                else
                    echo -e '\e[33mWarn: Loader: Invalid spinner nameref\e[0m'
                fi
                shift 2 ;;
            -l|--loop)
                if [[ "$2" =~ ^[0-9]+$ ]] ; then
                    loop="${2}"
                else
                    echo -e "\e[33mWarn: Loader: Invalid loop value '$2'\e[0m"
                fi
                shift 2 ;;
            -g|--gap)
                if [[ "$2" =~ ^[0-9]*\.?[0-9]+|[0-9]+\.?[0-9]*$ ]] ; then
                    if (( $2 > 0 )) ; then
                        gap="$2"
                    else
                        echo -e '\e[33mWarn: Loader: Gap must be higher than zero'
                    fi
                else
                    echo -e '\e[33mWarn: Loader: Gap must be a number or float\e[0m'
                fi
                shift 2 ;;
            *)
                echo -e "\e[33mWarn: Loader: Invalid option '$1'\e[0m"
                if [[ "$2" =~ '^-{1,2}' ]] ; then
                    shift
                else
                    shift 2
                fi ;;
        esac
    done

    local spinner_len="${#spinner[@]}"
    if [ -z "$gap" ] ; then
        gap="$(bc <<< "scale=2; 1/$spinner_len")"
    fi
    
    local spinner_char
    for ((i=0; i <= spinner_len * loop; i++)) ; do
        spinner_char="${spinner[$((i % spinner_len))]}"
        echo -en "${text//<spinner>/$spinner_char}"
        sleep "$gap"
        tput cr el
    done
}

term.prompt_yn() {
    local prompt; local yes='yes'; local no='no'
    while (( $# > 0 )) ; do
        case "$1" in
            -p)
                prompt="$2 "
                shift 2 ;;
            -y)
                yes="$2"
                shift 2 ;;
            -n)
                no="$2"
                shift 2 ;;
            *)
                shift ;;
        esac
    done

    yes_pre="${yes:0:1}"
    no_pre="${no:0:1}"
    yes="${M}(${yes_pre^^})${C}${yes:1}"
    no="${M}(${no_pre^^})${C}${no:1}"

    local code
    local invalid_opt=false
    while true ; do
        tput cr el civis
        echo -ne "${C}[?] ${prompt}${yes}, ${no}${X}"
        if ( "$invalid_opt" ) ; then
            echo -ne "${R} | Invalid entry \e[1m'$REPLY'${X}"
        fi
        read -rsn1 -p ''
        case "$REPLY" in
            "${yes_pre,,}"|"${yes_pre^^}") code=0 ;;
            "${no_pre,,}"|"${no_pre^^}") code=1 ;;
            *) invalid_opt=true; continue ;;
        esac
        break
    done
    echo ; tput cnorm
    return "$code"
}

term.start_screen() {
    ( "$MULTIPLEX_TERM" ) || return 0
    tput smcup && SCREEN_LAYER=$((SCREEN_LAYER + 1))
    tput cup 0 0 cr el civis
}

term.exit_screen() {
    ( "$MULTIPLEX_TERM" ) || return 0
    while (( SCREEN_LAYER > 0 )) ; do
        tput rmcup && SCREEN_LAYER=$((SCREEN_LAYER - 1))
    done
}

term.draw_hl() {
    local clr_start clr_end
    if [ -n "$1" ] ; then
        clr_start="$1"
        clr_end="$X"
    fi
    local cols; cols="$(tput cols)"
    local hl=''
    for ((i=0; i < cols; i++)) ; do
        hl+="─"
    done
    echo -e "${clr_start}${hl}${clr_end}"
}

cleanup() {
    trap - ERR INT TERM HUP QUIT
    trap 'term.exit_screen; exit 1' ERR
    trap 'term.exit_screen; exit 0' INT TERM HUP QUIT
    local abort="${1,,}"
    if [ "$abort" == 'true' ] && ( "$MULTIPLEX_TERM" ) ; then
        loader -s CMAP_MOON -t '\e[31mAB\e[33m<spinner>\e[31mRTING...\e[0m'
    else
        abort=false
    fi
    # Comment if statement if no alt screen
    local missing_log_file=false
    if ( ! $abort ) && ( "$MULTIPLEX_TERM" ) &&\
    ! term.prompt_yn -y 'Quit' -n 'View Logs' ; then
        clear
        if [ -f "$LOG_FILE" ] ; then
            less -R "$LOG_FILE"
        else
            missing_log_file=true
        fi
    fi
    term.exit_screen
    tput cnorm
    #shellcheck disable=SC2016
    ( "$missing_log_file" ) && log.warn 'No log file to open, see `egg -h`'
    exit 0
}

egg.print_help() {
cat << 'EOF'
Usage: egg ACTION [OPTION...]
Backup (lay) and restore (hatch) Thunderbird profiles.
See `egg ACTION --help` for action help

Actions:
  lay    Backup a Thunderbird profile
  hatch  Restore a Thunderbird profile

Options:
  -v, --verbose  Enable verbose logging
  -l, --logfile  Enable logging to file ~/.tb-egg.log
  -u, --uniterm  Disable terminal multiplexing
  -V, --version  Print Thunder-Egg version
  -h, --help     Print this help message

Examples:
  egg lay                    # Interactively backup a profile
  egg lay -p foo             # Backup profile 'foo' to current directory
  egg lay -s ~/foo -d ~/bar  # Source from 'foo' & backup to 'bar'
  egg hatch                  # Interactively restore a profile
  egg hatch -s foo.tar.xz    # Restore profile to default directory
  egg hatch -x -e foo.tar.xz # Execute Thunderbird with egg 'foo'

EOF
}

egg.lay.print_help() {
cat << 'EOF'
Usage: egg lay [OPTION...]
Backup Thunderbird profiles. See `egg --help` for general help.

Options:
  -s, --source PATH   Thunderbird source directory, defaults to ~/.thunderbird
  -d, --dest PATH     Output directory to lay egg in, defaults to PWD
  -p, --profile NAME  Thunderbird profile name to backup
  -a, --alias-file    Alias rules file name, defaults to 'alias_rules.json'
  -i, --iso           Use human-readable timestamp instead of Unix epoch
  -h, --help          Print this help message

Examples:
  egg lay                   # Interactively backup a profile
  egg lay -p foo            # Backup profile 'foo' to current directory
  egg lay -s ~/foo -d ~/bar # Source from 'foo' & backup to 'bar'
EOF
}

egg.hatch.print_help() {
cat << 'EOF'
Usage: egg hatch [OPTION...]
Restore Thunderbird profiles. See `egg --help` for general help.

Options:
  -s, --source PATH  Thunderbird egg to restore
  -d, --dest PATH    Path to Thunderbird directory, defaults to ~/.thunderbird
  -e, --exec         Execute Thunderbird with profile after hatching
  -h, --help         Print this help message

Examples:
  egg hatch                  # Interactively restore a profile
  egg hatch -s foo.tar.xz    # Restore profile to default directory
  egg hatch -x -e foo.tar.xz # Execute Thunderbird with egg 'foo'
EOF
}

egg.print_version() {
    echo -e "${C}Thunderbird Egg v${EGG_VERSION}${X}"
}

egg.parse_opts() {
    local code opts opts_len val
    while (( $# > 0 )) ; do
        if [[ "$1" =~ ^-[a-zA-Z0-9]{2,}$ ]] ; then
            # Handles options like `foo -abc val`
            opts="${1//-/}"
            opts_len="${#opts}"
            val=''
            for ((i=0; i < opts_len; i++)) ; do
                if (( i + 1 == opts_len )) &&\
                 [[ ! "$2" =~ ^-{1,2} ]] &&\
                 [ -n "$2" ] ; then
                    val="$2"
                fi
                egg.parse_opts "-${opts:$i:1}" "$val" || return 1
            done
            # Code set on iteration
            [ -n "$val" ] && code=2 || code=1
            shift "$code"
            continue
        fi

        if [[ "$action" =~ ^(lay|hatch)$ ]] ; then
            "egg.${action}.parse_opts" "$1" "$2"
            code="$?"
            if [[ "$code" =~ ^[1-2]$ ]] ; then
                shift "$code"
                continue
            elif [ "$code" == '3' ] ; then
                return 1
            fi
        fi
        case "$1" in
            -v|--verbose)
                VERBOSE_LOG=true
                shift ;;
            -l|--logfile)
                LOG_TO_FILE=true
                shift ;;
            -u|--uniterm)
                MULTIPLEX_TERM=false
                shift ;;
            -V|--version)
                egg.print_version
                exit 0 ;;
            -h|--help)
                egg.print_help
                exit 0 ;;
            '')
                shift ;;
            *)
                log.error "Invalid option '$1'"
                return 1 ;;
        esac
    done
}

egg.lay.parse_opts() {
    case "$1" in
        -s|--source)
            if [ -z "$2" ] || [ ! -d "$2" ] ; then
                log.error "'$1' missing or invalid Thunderbird directory"
                return 3
            fi
            SOURCE_PATH="$2"
            return 2 ;;
        -d|--dest)
            if [ -z "$2" ] ; then
                log.error "'$1' missing destination directory"
                return 3
            fi
            DEST_PATH="$2"
            return 2 ;;
        -p|--profile)
            if [ -z "$2" ] ; then
                log.error "'$1' missing Thunderbird profile name"
                return 3
            fi
            PROFILE_NAME="$2"
            return 2 ;;
        -a|--alias-file)
            if [ -z "$2" ] ; then
                log.error "'$1' missing alias rules file name"
                return 3
            fi
            ALIAS_RULES_FILE="$2"
            return 2 ;;
        -i|--iso)
            ISO_TIMESTAMP=true
            return 1 ;;
        -h|--help)
            egg.lay.print_help
            exit 0 ;;
        '')
            return 1 ;;
        *)
            return ;;
    esac
}

egg.hatch.parse_opts() {
    case "$1" in
        -s|--source)
            if [ -z "$2" ] || [ ! -f "$2" ] ; then
                log.error "'$1' missing or invalid egg/tar file"
                return 3
            fi
            SOURCE_PATH="$2"
            return 2 ;;
        -d|--dest)
            if [ -z "$2" ] || [ ! -d "$2" ] ; then
                log.error "'$1' missing or invalid Thunderbird directory"
                return 3
            fi
            DEST_PATH="$2"
            return 2 ;;
        -x|--exec)
            EXECUTE_AFTER=true
            return 1 ;;
        -h|--help)
            egg.hatch.print_help
            exit 0 ;;
        '')
            return 1 ;;
        *)
            return ;;
    esac
}

config.generate_profiles() {
# 'FDC34C9F024745EB' denotes a Debian, Ubuntu or Arch install of Thunderbird
cat << 'EOF'
[InstallFDC34C9F024745EB]
Default=<PROFILE>
Locked=1

[Profile0]
Name=<PROFILE_NAME>
IsRelative=1
Path=<PROFILE>

[General]
StartWithLastProfile=1
Version=2
EOF
}

config.generate_installs() {
cat << 'EOF'
[FDC34C9F024745EB]
Default=<PROFILE>
Locked=1
EOF
}

egg.compress() {
    log.info 'Compressing Egg'
    local backup_path="${1}/${2}"
    local -n backup_targets="$3"

    local opts
    ( "$VERBOSE_LOG" ) && opts='-vv'

    local tar_out status
    tar_out="$(tar $opts -cJf "${backup_path}.tar.xz" "${backup_targets[@]}" 2>&1)"
    status="$?"

    if [ -n "$tar_out" ] ; then
        local hl ; hl="$(term.draw_hl "$R")"
        log.echo "${hl}${tar_out}\n${hl}"
    fi
    return "$status"
}

egg.decompress() {
    log.info 'Decompressing Egg'
    local source_path="$1"
    local profile_path="$2"

    local opts
    ( "$VERBOSE_LOG" ) && opts='-vv'

    local tar_out status
    tar_out="$(tar $opts --force-local -xf "$source_path" -C "$profile_path"/ 2>&1)"
    status="$?"

    if [ -n "$tar_out" ] ; then
        local hl; hl="$(term.draw_hl "$R")"
        log.echo "${hl}${tar_out}\n${hl}"
    fi
    return "$status"
}

# egg.extract_profile_names() {
#     local profiles_ini="$1"

#     local profiles
#     if [ -f "$profiles_ini" ] ; then
#         grep -oP '(?<=^Path=).*' "$profiles_ini" 2>/dev/null
#     fi
# }

egg.lay() {
    log.info2 'Laying Thunderbird Egg'

    local source_path="$SOURCE_PATH"
    [ -z "$source_path" ] && source_path="$DEFAULT_TBIRD_DIR"
    if [ ! -d "$source_path" ] ; then
        log.warn "Directory does not exist '$source_path'"
        while true ; do
            if ! source_path="$(zenity --file-selection \
            --title 'Thunderbird Directory' --directory 2>/dev/null)" ; then
                log.error 'Cannot establish Thunderbird directory'
                return 1
            elif [ -z "$source_path" ] || [ ! -d "$source_path" ] ; then
                log.warn 'Invalid selection or directory'
                continue
            fi
            break
        done
    fi
    log.info "Thunderbird Dir ${M}${source_path}"

    local profile="$PROFILE_NAME"
    local profile_path="${source_path}/${profile}"
    if [ -z "$profile" ] || [ ! -d "$profile_path" ] ; then
        if [ -n "$profile" ] ; then
            log.warn "Profile '$profile' does not exist"
        fi

        # local profiles
        # profiles="$(egg.extract_profile_names "$source_path/profiles.ini")"
        # while [ -n "$profiles" ] ; do
        #     if ! profile="$(echo "$profiles" | zenity --list \
        #     --title 'Thunderbird Profile' --column 'Profile' --width 400 \
        #     --height 300 2>/dev/null)" ; then
        #         log.error 'No profile selected'
        #         return 1
        #     fi
        #     if [ -z "$profile" ] || [ ! -d "$source_path"/"$profile" ] ; then
        #         log.warn "Profile '$profile' does not exist in '$source_path'"
        #         continue
        #     fi
        #     break
        # done

        while [ -z "$profile" ] ; do
            if ! profile_path="$(zenity --file-selection \
            --filename "$source_path/" --directory 2>/dev/null)" ; then
                log.error 'No profile selected'
                return 1
            fi
            if [ -d "$profile_path" ] ; then
                profile="${profile_path##*/}"
                log.info "Profile found '$profile'"
            fi
        done
    fi
    log.info "Profile ${M}${profile}"

    local dest_path="$DEST_PATH"
    if [ ! -d "$dest_path" ] || [ ! -w "$dest_path" ] ; then
        [ -n "$dest_path" ] && log.warn "Directory does not exist '$dest_path'"
        while true ; do
            if ! dest_path="$(zenity --file-selection \
            --title 'Output Directory' --directory 2>/dev/null)" ; then
                log.error 'No directory selected'
            elif [ -z "$dest_path" ] || [ ! -d "$dest_path" ] ; then
                log.warn 'Invalid selection or directory'
                continue
            fi
            break
        done
    fi
    log.info "Backup Dir ${M}${dest_path}"

    cd "$profile_path" || return 1

    local timestamp
    if ( "$ISO_TIMESTAMP" ) ; then
        timestamp="$(time.datetime)"
    else
        timestamp="$(time.epoch)"
    fi
    local out="${profile}@${timestamp}"

    if [ -z "$ALIAS_RULES_FILE" ] ; then
        ALIAS_RULES_FILE="$DEFAULT_ALIAS_RULES_FILE"
    fi
    BACKUP_TARGETS+=( "$ALIAS_RULES_FILE" )

    local targets=()
    for target in "${BACKUP_TARGETS[@]}" ; do
        if [ ! -e "$target" ] ; then
            log.warn "Skipping nonexistent backup target '$target'"
            continue
        fi
        ( "$VERBOSE_LOG" ) && log.ok "Adding '$target' to egg"
        targets+=("$target")
    done

    if egg.compress "${dest_path}" "${out}" 'targets' ; then
        log.info "${C}Egg Laid ${Y}@ ${M}${out}.tar.xz"
        return 0
    fi
    log.error 'Failed to lay egg'
    return 1
}

egg.hatch() {
    log.info2 'Hatching Thunderbird Egg'

    local source_path="$SOURCE_PATH"
    if [ ! -f "$source_path" ] ; then
        [ -n "$source_path" ] && log.warn "Source does not exist '$source_path'"
        while true ; do
            if ! source_path="$(zenity --file-selection \
            --title 'Thunderbird Egg to Hatch' \
            --file-filter 'Egg (profile@date.tar.xz) | *@*.tar.xz' \
            --file-filter '.tar.xz | *.tar.xz' \
            --file-filter 'All Files | *' \
            2>/dev/null)" ; then
                log.error 'No backup egg to restore'
                return 1
            elif [ -z "$source_path" ] || [ ! -f "$source_path" ] ; then
                log.warn 'Invalid selection or file'
                continue
            fi
            break
        done
    fi
    local egg_file="${source_path##*/}"
    log.info "Thunderbird Egg ${M}$egg_file"

    local dest_path="$DEST_PATH"
    if [ -z "$dest_path" ] ; then
        dest_path="$DEFAULT_TBIRD_DIR"
        mkdir -p "$dest_path"
    fi
    if [ ! -d "$dest_path" ] ; then
        log.warn "Directory does not exist '$dest_path'"
        while true ; do
            if ! dest_path="$(zenity --file-selection \
            --title 'Thunderbird Directory' \
            --directory \
            2>/dev/null)" ; then
                log.error 'Cannot establish Thunderbird directory'
                return 1
            elif [ -z "$dest_path" ] || [ ! -d "$dest_path" ] ; then
                log.warn 'Invalid selection or directory'
                continue
            fi
            break
        done
    fi
    log.info "Thunderbird Dir ${M}${dest_path}"

    # Tails has one profile 'profile.default' and cannot access ProfileManager
    # without calling Thunderbird bin directly from /usr/lib/thunderbird/...

    local profile
    local tails_os=false
    if [ "$(lsb_release -si 2>/dev/null)" == 'Tails' ] ; then
        tails_os=true
        profile='profile.default'
    else
        profile="$(grep -oP '[^/]+(?=@[^/]*\.tar\.xz$)' <<< "$egg_file")"
    fi

    local profile_path="${dest_path}/${profile}"
    if ! mkdir -p "$profile_path" ; then
        log.error "Failed to make dir '$profile_path'"
        return 1
    elif ! egg.decompress "$source_path" "$profile_path/" ; then
        log.error 'Failed to hatch egg'
        return 1
    fi
    log.info "Profile '$profile' hatched"

    # Tails OS doesn't use profiles.ini or installs.ini at all?
    if [ ! -f "$dest_path"/profiles.ini ] && ( ! "$tails_os" ) ; then
        local conf
        log.info 'Generating profiles.ini'
        conf="$(config.generate_profiles |\
            sed "s/<PROFILE>/$profile/g; s/<PROFILE_NAME>/${profile##*.}/g")"
        echo "$conf" > "$dest_path"/profiles.ini

        log.info 'Generating installs.ini'
        if [ -f "$dest_path"/installs.ini ] ; then
            term.prompt_yn -p "Replace existing 'installs.ini'" || return
        fi
        conf="$(config.generate_installs |\
            sed "s/<PROFILE>/$profile/g")"
        echo "$conf" > "$dest_path"/installs.ini
    fi

    # TODO: Consider executing Thunderbird after final cleanup in egg.init to
    # prevent script from hanging in background when in multiplex mode (default)

    if ( "$EXECUTE_AFTER" ) ; then
        log.info 'Attempting to start Thunderbird'
        setsid thunderbird --profile "$profile_path" 1>/dev/null 2>"$LOG_FILE" &
    fi
}

egg.init() {
    local action
    if [[ ! "$1" =~ ^-+ ]] ; then
        action="${1,,}"
        shift
    fi
    LOG_FILE='/dev/null'
    egg.parse_opts "$@" || return 1
    if ( "$LOG_TO_FILE" ) ; then
        LOG_FILE="$HOME/.tb-egg.log"
        [ -f "$LOG_FILE" ] && mv -f "$LOG_FILE" "$LOG_FILE~"
    fi

    case "$action" in
        'lay')
            [ -z "$DEST_PATH" ] && DEST_PATH="$(pwd)"
            term.start_screen
            egg.lay || return 1 ;;
        'hatch')
            term.start_screen
            egg.hatch || return 1 ;;
        *)
            log.error "Invalid action '$action'"
            exit 1 ;;
    esac
    cleanup
}

trap 'log.error "An error has occurred"; cleanup true' ERR
trap 'log.warn "Canceling process" ; cleanup true' INT TERM HUP QUIT

egg.init "$@" || cleanup true
