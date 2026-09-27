;;; config-llm.el --- LLM configuration -*- lexical-binding: t; -*-

;;; Commentary:
;; Configuration for LLM integrations

;;; Code:

;; ── gptel ──────────────────────────────────────────────────────────────

(use-package gptel
  :ensure t
  :config
  (setq gptel-api-key "your key")
  (setq gptel-default-mode 'org-mode)
  (gptel-make-openai "Beellama"             ;Any name of your choosing
    :protocol "http"
    :host "desktop-pc:8060"               ;Where it's running
    :stream t                             ;Stream responses
    :models '(Qwen3.6-27B-MTP-IQ4_KS.gguf))
  
  (gptel-make-openai "Ollama"             ;Any name of your choosing
    :protocol "http"
    :host "desktop-pc:11434"               ;Where it's running
    :stream t                             ;Stream responses
    :models '(muse-glimmer:30b hf.co/unsloth/Qwen3.8-27B-GGUF:Q4_K_M hf.co/unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_XL))

  (setq gptel-backend
        (gptel-make-openai "Qwen3.8"             
          :protocol "http"
          :host "desktop-pc:8090"               
          :stream t                             
          :models '(qwen3.8-27b))
        ))

(use-package gptel-agent
  :ensure t 
  :config (gptel-agent-update))         ;Read files from agents directories

;; ── shell-maker (create custom shells in eshell) ──────────────────────

(use-package shell-maker
  :ensure t
  :config
  (advice-add 'shell-maker-submit :after
              (lambda (&rest _)
                (goto-char (point-max))
                (evil-normal-state 1)
                )))

;; ── agent-shell ecosystem ─────────────────────────────────────────────

(use-package exec-path-from-shell
  :ensure t
  :config
  ;; Only initialize if we are NOT on Windows
  (unless (eq system-type 'windows-nt)
    (exec-path-from-shell-initialize))

  )

;; (use-package pinentry
;;   :ensure t)

;; ── acp (agent client protocol) ───────────────────────────────────────────
(use-package acp
  :ensure t)

;; ── agent-shell + notifications + bookmarks ────────────────────────────

(use-package agent-shell-links
  :vc (:url "https://github.com/ultronozm/agent-shell-links.el" :rev "newest")
  :config
  ;;(agent-shell-links-bookmark-setup)
  (with-eval-after-load 'ol
    (org-link-set-parameters
     "agent-shell"
     :follow #'agent-shell-links-org-follow
     :store #'agent-shell-links-org-store)))

;; ── agent-recall (search/browse agent-shell transcripts) ───────────────

(use-package agent-recall
  :ensure t
  :hook (agent-shell-mode . agent-recall-track-sessions)
  :config
  (setq agent-recall-search-paths '("~/Dropbox" "~/.config/emacs" "~/projects" "~/work" "~/.agent-shell")
        agent-recall-search-function 'consult-ripgrep
        agent-recall-browse-sort 'modified-desc))

;; ── Aidermacs (Aider integration) ─────────────────────────────────────
(use-package aidermacs
  :ensure t
  :bind (("C-c a" . aidermacs-transient-menu))
  :config
  ;; Pre-run hook to configure Ollama host for Aider via env vars
  (add-hook 'aidermacs-before-run-backend-hook
            (defun my/aider-setup ()
              (setenv "OLLAMA_API_BASE" "http://desktop-pc:11434")
              (setenv "AWS_PROFILE" "hermes")
              ))
  (setq 
   ;;aidermacs-default-model "ollama_chat/muse-glimmer:30b"
   aidermacs-default-model "bedrock/converse/us.anthropic.claude-sonnet-4-5-20250929-v1:0"
   ;;aidermacs-editor-model "ollama_chat/muse-glimmer:30b"
   aidermacs-editor-model "bedrock/converse/us.anthropic.claude-sonnet-4-5-20250929-v1:0"
   aidermacs-editor-model "ollama_chat/muse-glimmer:30b"
   aidermacs-default-chat-mode 'code
   aidermacs-extra-args '("--no-show-model-warnings")
   )
  :custom
  ;; Keep changes explicit, no auto-commits by default
  (aidermacs-auto-commits nil)
  (aidermacs-show-diff-after-change t)
  (aidermacs-backend 'comint))

;; ── Launch aidermacs with qwen3.8-27b via llama.cpp:8086 ─────────────
(defun my/aider-qwen38--env-setup ()
  "Set env vars for llama.cpp:8086 backend."
  (setenv "OPENAI_BASE_URL" "http://desktop-pc:8086/v1")
  (setenv "OPENAI_API_KEY" "llama"))

(defun my/aider-qwen38 ()
  "Launch aidermacs using qwen3.8-27b served at desktop-pc:8086."
  (interactive)
  (let ((aidermacs-default-model "openai/qwen3.8-27b")
        (aidermacs-editor-model "openai/qwen3.8-27b")
        (aidermacs-extra-args '("--no-show-model-warnings" "--yes-always")))
    (add-hook 'aidermacs-before-run-backend-hook #'my/aider-qwen38--env-setup)
    (unwind-protect
        (aidermacs-run)
      (remove-hook 'aidermacs-before-run-backend-hook #'my/aider-qwen38--env-setup))))

;; ── agent-shell ecosystem ─────────────────────────────────────────────

;; (use-package pinentry
;;   :ensure t)

;; ── acp (agent client protocol) ───────────────────────────────────────────
(use-package acp
  :ensure t)

;; ── agent-shell + notifications + bookmarks ────────────────────────────

(use-package agent-shell
  :hook (agent-shell-mode . rs/shell-scroll-setup)
  :ensure t
  :defer t
  :config
  (setq 
   agent-shell-opencode-environment
   (agent-shell-make-environment-variables
    "OPENCODE_ENABLE_EXA" "1"
    )
   agent-shell-pi-environment
   (agent-shell-make-environment-variables
    ;; "PI_ACP_PI_COMMAND" "little-coder"
    "LITTLE_CODER_BASH_ALLOW" "docker ,npm ,tmux, emacsclient"
    ))
  (add-to-list 'agent-shell-agent-configs (agent-shell-hermes-make-agent-config) t)
  (setq agent-shell-confirm-interrupt nil
        agent-shell-header-style 'text
        agent-shell-hermes-acp-command '("hermes" "-p" "chief-of-staff" "acp"))
  ;; (add-hook 'diff-mode-hook
  ;;           (lambda ()
  ;;             (when (string-match-p "\\*agent-shell-diff\\*" (buffer-name))
  ;;               (evil-emacs-state))))
  ;; Mode-specific keys — only active in agent-shell-mode buffers
  ;; (general-define-key
  ;;  :states 'normal
  ;;  :keymaps 'agent-shell-mode-map
  ;;  "["   #'agent-shell-previous-item
  ;;  "]"   #'agent-shell-next-item
  ;;  "TAB" #'agent-shell-ui-toggle-fragment
  ;;  "q"   #'agent-shell-toggle
  ;;  "c"   #'agent-shell-prompt-compose
  ;;  "x"   #'agent-shell-interrupt)
  ;; 
  (defun agent-shell/setup ()
    (evil-collection-unimpaired-mode -1)
    (evil-commentary-mode -1)
    (evil-define-key 'normal agent-shell-mode-map
      [tab]       #'agent-shell-ui-toggle-fragment
      (kbd "TAB") #'agent-shell-ui-toggle-fragment
      (kbd "]")   #'agent-shell-next-item
      (kbd "[")   #'agent-shell-previous-item)
    )
  

  (add-hook 'agent-shell-mode-hook #'agent-shell/setup)

  (with-eval-after-load 'evil-collection-agent-shell
    (agent-shell/setup)
    )
  )

(use-package agent-shell-tramp
  :vc (:url "https://github.com/junyi-hou/agent-shell-tramp" :rev "14560d42440c17d9b59fc18d304687641ddf06e5")
  :config
  (agent-shell-tramp-mode 1)
  ;; (connection-local-set-profile-variables
  ;;  'remote-direct-async-process
  ;;  '((tramp-direct-async-process . t)))
  ;; 
  ;; (connection-local-set-profiles
  ;;  '(:application tramp)
  ;;  'remote-direct-async-process)


  )

(use-package agent-shell-bookmark
  :vc (:url "https://github.com/dcluna/agent-shell-bookmark" :rev "c1eab34bff4f35bf929885ed5045c6100afcf496")
  :config

  (defun my-agent-shell-bookmark--find-config (agent-identifier)
    "Find config by identifier, supporting both maker symbols and alists."
    (when agent-identifier (or
                            ;; Newer style: maker function symbols
                            (let ((maker
                                   (seq-find (lambda (entry)
                                               (and (symbolp entry) (string-match-p (format "-%s-" (symbol-name agent-identifier)) (symbol-name entry))))
                                             agent-shell-agent-configs)))
                              (when maker (funcall maker)))
                            ;; Older style: realized config alists
                            (seq-find (lambda (entry)
                                        (and (listp entry)
                                             (eq (alist-get :identifier entry) agent-identifier)))
                                      agent-shell-agent-configs))))

  (advice-add 'agent-shell-bookmark--find-config :override #'my-agent-shell-bookmark--find-config)
  )

;; ── agent-recall (search/browse agent-shell transcripts) ───────────────

(use-package agent-recall
  :ensure t
  :hook (agent-shell-mode . agent-recall-track-sessions)
  :config
  (setq agent-recall-search-paths '("~/Dropbox" "~/.config/emacs" "~/projects" "~/work" "~/.agent-shell")
        agent-recall-search-function 'consult-ripgrep
        agent-recall-browse-sort 'modified-desc))


(use-package agent-shell-attention
  :vc (:url "https://github.com/ultronozm/agent-shell-attention.el" :rev "main")
  :config
  (unless (eq system-type 'windows-nt)
    (agent-shell-attention-mode 1))
  (setopt agent-shell-attention-notify-function #'agent-shell-attention-notify-default)
  )

;; (use-package agent-shell-sidebar
;;   :after agent-shell
;;   :vc (:url "https://github.com/rashid301/agent-shell-sidebar")
;;   :custom
;;   ;; Default minimum-width (80 columns) was overriding `agent-shell-sidebar-width'
;;   ;; ("25%"), since 25% of this frame (191 cols) is only ~48 columns.  Lower the
;;   ;; floor so the percentage actually applies.
;;   (agent-shell-sidebar-minimum-width 40)
;;   :config
;;   ;; Newer agent-shell defaults `agent-shell-agent-configs' to a list of
;;   ;; config MAKER functions (see `agent-shell-default-agent-config-makers')
;;   ;; rather than realized config alists.  `agent-shell-sidebar--select-config'
;;   ;; predates that convention and calls `map-elt' directly on each entry,
;;   ;; which throws `cl-no-applicable-method' when an entry is a raw function
;;   ;; symbol (e.g. `agent-shell-antigravity-make-agent-config').  Override it
;;   ;; to realize maker-function entries (and a function-valued
;;   ;; `agent-shell-agent-configs' itself) before treating them as alists.
;;   (defun my/agent-shell-sidebar--select-config ()
;;     "Select an agent config for the sidebar, resolving maker functions."
;;     (or agent-shell-sidebar-default-config
;;         (let* ((configs (if (functionp agent-shell-agent-configs)
;;                             (funcall agent-shell-agent-configs)
;;                           agent-shell-agent-configs))
;;                (resolved (mapcar (lambda (entry)
;;                                    (if (functionp entry) (funcall entry) entry))
;;                                  configs))
;;                (choices (mapcar (lambda (config)
;;                                   (cons (or (map-elt config :mode-line-name)
;;                                             (map-elt config :buffer-name)
;;                                             "Unknown Agent")
;;                                         config))
;;                                 resolved))
;;                (selected-name (completing-read "Select agent: " choices nil t)))
;;           (map-elt choices selected-name))))
;; 
;;   (advice-add 'agent-shell-sidebar--select-config :override #'my/agent-shell-sidebar--select-config)
;; 
;;   ;; `agent-shell-sidebar--start-session' copies CONFIG and tries to add
;;   ;; brand-new `:no-focus' / `:new-session' keys via `map-put!'.  On this
;;   ;; Emacs's `map.el', `map-put!' can only mutate an alist in place when the
;;   ;; key already exists (it does a `setcdr' on the existing cons); adding a
;;   ;; new key means prepending a cons, which isn't an in-place operation, so
;;   ;; it signals `map-not-inplace' instead of silently doing nothing.  Since
;;   ;; agent config alists never carry these two keys, override the function to
;;   ;; prepend them directly rather than relying on `map-put!' to grow the list.
;;   (cl-defun my/agent-shell-sidebar--start-session (&key config project-root)
;;     "Start new agent-shell sidebar session using CONFIG in PROJECT-ROOT."
;;     (let* ((state (agent-shell-sidebar--project-state project-root))
;;            (existing-buffer (map-elt state :buffer)))
;; 
;;       (when (and existing-buffer (buffer-live-p existing-buffer))
;;         (kill-buffer existing-buffer))
;; 
;;       (let* ((sidebar-config (append '((:no-focus . t) (:new-session . t)) config))
;;              (shell-buffer (agent-shell-start :config sidebar-config)))
;;         (with-current-buffer shell-buffer
;;           (setq-local agent-shell-sidebar--is-sidebar t)
;;           (add-hook 'kill-buffer-hook #'agent-shell-sidebar--clean-up nil t))
;; 
;;         (map-put! state :buffer shell-buffer)
;;         (map-put! state :config config)
;; 
;;         shell-buffer)))
;; 
;;   (advice-add 'agent-shell-sidebar--start-session :override #'my/agent-shell-sidebar--start-session)
;; 
;;   ;; `SPC p' is bound to `project-prefix-map' directly (see
;;   ;; config-keybindings.el), so bind the sidebar toggle at `SPC p a' by
;;   ;; adding to that keymap rather than the leader definer.
;;   (with-eval-after-load 'project
;;     (define-key project-prefix-map "a" #'agent-shell-sidebar-toggle)))


;; (use-package agent-shell-workspace
;;   :vc (:url "https://github.com/gveres/agent-shell-workspace")
;;   :ensure t
;;   :after agent-shell
;;   )

(provide 'config-llm)
;;; config-llm.el ends here
