;;; ============================================================================
;;; C3DTools-Config.lsp  -  settings for C3DTools
;;;
;;; Edit the values below, save, and restart Civil 3D (or open a new drawing).
;;; This file is plain text on purpose so CAD administrators can change it
;;; without rebuilding the application. Keep the ("Key" . value) shape.
;;;
;;;   T    means yes / on
;;;   nil  means no / off (or "use the default" for LogDir)
;;; ============================================================================

(setq *c3dt:config*
  '(
    ;; ---- Folders -----------------------------------------------------------

    ;; Where Health.csv, Events.csv, Opened.csv and the audit reports go.
    ;; nil = %LOCALAPPDATA%\C3DTools\Logs\ (per user, per machine).
    ;; Use forward slashes, e.g. "D:/CAD/C3DTools/Logs" or a shared
    ;; folder "//server/cad/C3DTools/Logs".
    ;; The C3DTOOLS_LOGDIR environment variable, if set, overrides this.
    ("LogDir" . nil)

    ;; ---- C3DGuard ----------------------------------------------------------

    ;; Percentage growth between saves that triggers a warning.
    ("GuardGrowthWarnPct" . 20)

    ;; ---- C3DAudit ----------------------------------------------------------

    ;; Re-audit the drawing being saved, after every save.
    ("AuditOnSave" . T)

    ;; ---- C3DImpact ---------------------------------------------------------

    ;; Impact warnings for grip edits, Civil 3D surface-edit commands and any
    ;; intercepted command. Users can change this in C3D-IMPACT-SETTINGS.
    ("ImpactWarnings" . T)

    ;; How often a warning appears, for users who have not chosen:
    ;;   "every"  every time the command runs
    ;;   "once"   the first time each command runs in a Civil 3D session
    ("ImpactWarnFrequency" . "every")

    ;; Whether users may turn on interception of MOVE, STRETCH, ROTATE and
    ;; SCALE in C3D-IMPACT-SETTINGS. Each intercepted command is UNDEFINED for
    ;; the session. Set to nil to prohibit it.
    ("ImpactInterceptAllowed" . T)

    ;; Interception for users who have not made their own choice:
    ;;   nil                     none (recommended)
    ;;   T                       all four commands
    ;;   ("MOVE" "ROTATE")       just the commands listed
    ;; Leave nil unless your firm has agreed to it.
    ("ImpactInterceptDefault" . nil)

    ;; Extra Civil 3D command names that should show the impact warning.
    ;; Only add names you have confirmed: run C3DGUARD-LOGCOMMANDS, start the
    ;; command from the ribbon, and copy the name printed on the command line.
    ;; Example:  ("ImpactExtraCommands" . ("AECCSOMECOMMAND" "AECCOTHER"))
    ("ImpactExtraCommands" . nil)
  )
)

(princ)
