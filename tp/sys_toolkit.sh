#!/bin/sh
# sys_toolkit.sh - Outil multi-fonction POSIX sh
# Auteur : (votre nom)
# Usage : ./sys_toolkit.sh <command> [options]

set -u  # erreur si variable non définie
# set -e  # (optionnel) arrêter à la 1ère erreur, mais attention aux pipelines

VERSION="1.0.0"

# --- Utilitaires génériques ---

log_info()  { printf "%s\n" "INFO: $*"; }
log_warn()  { printf "%s\n" "WARN: $*"; }
log_error() { printf "%s\n" "ERROR: $*" >&2; }

die() { log_error "$*"; exit 1; }

usage() {
  cat <<'EOF'
sys_toolkit.sh - Boîte à outils système (POSIX sh)

Usage:
  sys_toolkit.sh <command> [options]

Commands:
  help                       Affiche cette aide
  inspect <dir> [--pattern PAT] [--ext EXT]
  backup  <dir> --output FILE.tar.gz [--ext EXT]
  cleanup <dir> [--dry-run]
  process <file> [--top N]
  monitor

Notes:
  - Compatible POSIX sh (/bin/sh). Éviter les constructions spécifiques bash.
  - Les options longues sont analysées manuellement.
EOF
}

# --- Parsing simple des options longues ---
# Consigne : ne pas utiliser getopts pour options longues ; rester en POSIX.

# --- Commande: inspect ---
cmd_inspect() {
  [ $# -ge 1 ] || die "inspect: besoin d'un répertoire"
  DIR=$1; shift
  PATTERN=""
  EXT=""

  # Parsing options
  while [ $# -gt 0 ]; do
    case "$1" in
      --pattern)
        [ $# -ge 2 ] || die "inspect: --pattern requiert un argument"
        PATTERN=$2; shift 2 ;;
      --ext)
        [ $# -ge 2 ] || die "inspect: --ext requiert un argument (ex: .txt)"
        EXT=$2; shift 2 ;;
      *)
        die "inspect: option inconnue '$1'"
        ;;
    esac
  done

  [ -d "$DIR" ] || die "inspect: '$DIR' n'est pas un répertoire"

  log_info "Répertoire: $DIR"
  log_info "Taille (du):"
  du -sh "$DIR" 2>/dev/null || log_warn "du a échoué"

  log_info "Contenu (ls -la):"
  ls -la "$DIR" 2>/dev/null | sed -n '1,20p' || log_warn "ls a échoué"

  # Construction dynamique du prédicat find
  # -type f, optionnellement par extension, puis grep pattern
  if [ -n "$EXT" ]; then
    FIND_CMD="find \"$DIR\" -type f -name \"*${EXT}\""
  else
    FIND_CMD="find \"$DIR\" -type f"
  fi

  log_info "Fichiers correspondants:"
  # Éviter les problèmes d'espaces : utiliser xargs -0 si nécessaire (ici simple)
  # shellcheck disable=SC2016  # (pour info) pas utilisé ici
  if [ -n "$PATTERN" ]; then
    # Liste puis filtrage
    # Utiliser grep -H pour afficher le nom de fichier
    # Traiter les erreurs si grep retourne 1 (pas de match) -> ne pas die
    # Attention aux fichiers binaires : forcer -I pour ignorer si besoin
    # Ici, on utilise grep -n pour montrer les lignes
    # Remarque : POSIX grep n’a pas -I garanti ; on s’abstient.
    # On protège le pattern en double quotes.
    # On utilise set -e désactivé pour ne pas casser sur RC=1.
    # Filtrage :
    # shell POSIX : pas de arrays ; boucles textuelles.
    # On pourrait aussi faire : grep -R
    # Ici, on passe les chemins via xargs pour robustesse simple.
    # ATTENTION : espaces dans noms -> find -print0 + xargs -0 serait mieux.
    find "$DIR" -type f ${EXT:+-name "*$EXT"} -print0 \
      | xargs -0 grep -n -- "$PATTERN" 2>/dev/null \
      || log_warn "grep n'a trouvé aucun motif '$PATTERN'"
  else
    # Simple listing + stats
    # Afficher nombre de fichiers, tailles top
    FILES_COUNT=$(sh -c "find \"$DIR\" -type f | wc -l")
    printf "Nombre de fichiers: %s\n" "$FILES_COUNT"
    printf "Top 5 fichiers par taille:\n"
    # du -b n'est pas POSIX ; utiliser -k (kibibytes) ou -h (humain, non POSIX strict)
    # On va utiliser 'stat' si disponible ; sinon du -k :
    find "$DIR" -type f -print0 \
      | xargs -0 du -k 2>/dev/null \
      | sort -nr | head -n 5
  fi
}

# --- Commande: backup ---
cmd_backup() {
  [ $# -ge 1 ] || die "backup: besoin d'un répertoire"
  DIR=$1; shift
  OUT=""
  EXT=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --output)
        [ $# -ge 2 ] || die "backup: --output requiert un fichier .tar.gz"
        OUT=$2; shift 2 ;;
      --ext)
        [ $# -ge 2 ] || die "backup: --ext requiert une extension (ex: .txt)"
        EXT=$2; shift 2 ;;
      *)
        die "backup: option inconnue '$1'"
        ;;
    esac
  done

  [ -d "$DIR" ] || die "backup: '$DIR' n'est pas un répertoire"
  [ -n "$OUT" ] || die "backup: fichier de sortie requis via --output"

  TMP_LIST=$(mktemp) || die "mktemp a échoué"
  # Sélection des fichiers :
  if [ -n "$EXT" ]; then
    find "$DIR" -type f -name "*$EXT" -print > "$TMP_LIST"
  else
    find "$DIR" -type f -print > "$TMP_LIST"
  fi

  log_info "Création de l'archive: $OUT"
  # Créer un tar depuis la liste
  # tar --files-from est GNU ; POSIX: utiliser xargs
  # On se place dans DIR pour éviter chemins absolus
  (
    cd "$DIR" || exit 1
    # Transformer la liste en chemins relatifs
    sed "s#^$DIR/##" "$TMP_LIST" \
      | tar -czf "$OUT" -T - 2>/dev/null
  ) || die "tar/gzip a échoué"

  rm -f "$TMP_LIST"
  log_info "Archive créée: $OUT"
}

# --- Commande: cleanup ---
cmd_cleanup() {
  [ $# -ge 1 ] || die "cleanup: besoin d'un répertoire"
  DIR=$1; shift
  DRY_RUN=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --dry-run) DRY_RUN=1; shift ;;
      *) die "cleanup: option inconnue '$1'";;
    esac
  done

  [ -d "$DIR" ] || die "cleanup: '$DIR' n'est pas un répertoire"

  # Fichiers temporaires/journaux courants
  # Attention aux expansions ; utiliser find.
  PAT='\( -name "*.tmp" -o -name "*.log" -o -name "*~" -o -name "*.bak" \)'
  if [ "$DRY_RUN" -eq 1 ]; then
    log_info "Mode simulation: fichiers qui seraient supprimés :"
    # shellcheck disable=SC2086
    eval find \""$DIR"\" -type f $PAT -print
  else
    log_info "Suppression des fichiers temporaires:"
    # shellcheck disable=SC2086
    eval find \""$DIR"\" -type f $PAT -print -delete 2>/dev/null \
      || log_warn "delete non supporté, fallback rm"
    # Fallback si -delete n’est pas dispo :
    # eval find \""$DIR"\" -type f $PAT -print | xargs rm -f
  fi
}

# --- Commande: process (texte) ---
cmd_process() {
  [ $# -ge 1 ] || die "process: besoin d'un fichier texte"
  FILE=$1; shift
  TOP=10
  while [ $# -gt 0 ]; do
    case "$1" in
      --top) [ $# -ge 2 ] || die "process: --top requiert N"
             TOP=$2; shift 2 ;;
      *) die "process: option inconnue '$1'";;
    esac
  done

  [ -f "$FILE" ] || die "process: '$FILE' n'est pas un fichier"

  log_info "Statistiques sur '$FILE'"
  printf "Lignes : "; wc -l < "$FILE"
  printf "Mots   : "; wc -w < "$FILE"
  printf "Octets : "; wc -c < "$FILE"

  # Nettoyage simple : minuscules, retirer ponctuation, découper en mots
  # POSIX: tr pour transformer, sed pour filtrer
  # Compter les occurrences puis trier
  tr '[:upper:]' '[:lower:]' < "$FILE" \
    | tr -c '[:alnum:]' '\n' \
    | sed '/^$/d' \
    | sort \
    | uniq -c \
    | sort -nr \
    | head -n "$TOP"
}

# --- Commande: monitor ---
cmd_monitor() {
  printf "Date: "; date
  printf "Hôte : "; hostname
  printf "Noyau: "; uname -sr
  printf "Disque:\n"; df -h | sed -n '1,5p'
  printf "Top dossiers (taille):\n"
  du -h . 2>/dev/null | sort -hr | head -n 5
  printf "Processus courants:\n"
  ps -eo pid,comm,pcpu,pmem --no-headers | sort -k3nr | head -n 5
}

# --- Router principal ---
main() {
  [ $# -ge 1 ] || { usage; exit 0; }
  CMD=$1; shift
  case "$CMD" in
    help|-h|--help) usage ;;
    inspect)        cmd_inspect "$@" ;;
    backup)         cmd_backup "$@" ;;
    cleanup)        cmd_cleanup "$@" ;;
    process)        cmd_process "$@" ;;
    monitor)        cmd_monitor "$@" ;;
    version|-v|--version) printf "%s\n" "$VERSION" ;;
    *)    *) die "Commande inconnue: $CMD (essayez 'help')" ;;
  esac
}
