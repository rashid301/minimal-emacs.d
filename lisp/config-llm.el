;;; config-llm.el --- LLM configuration -*- lexical-binding: t; -*-

;;; Commentary:
;; Configuration for LLM integrations

;;; Code:

;; ── gptel ──────────────────────────────────────────────────────────────

(use-package gptel
  :ensure t
  :config
  (setq gptel-api-key "your key")
  (setq gptel-backend (gptel-make-openai "Beellama"             ;Any name of your choosing
                        :protocol "http"
                        :host "desktop-pc:8060"               ;Where it's running
                        :stream t                             ;Stream responses
                        :models '(Qwen3.6-27B-MTP-IQ4_KS.gguf))
        )
  (gptel-make-openai "Ollama"             ;Any name of your choosing
    :protocol "http"
    :host "desktop-pc:11434"               ;Where it's running
    :stream t                             ;Stream responses
    :models '(muse-glimmer:30b hf.co/unsloth/Qwen3.8-27B-GGUF:Q4_K_M hf.co/unsloth/Qwen3.8-27B-GGUF:UD-Q4_K_XL))
  
  )

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
  (exec-path-from-shell-initialize)
  )

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
  (setq agent-shell-anthropic-claude-environment
        (agent-shell-make-environment-variables
         "AWS_PROFILE" "hermes"
         )
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
        agent-shell-header-style 'graphical
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
  (setq aidermacs-default-model "ollama_chat/muse-glimmer:30b"
        aidermacs-editor-model "ollama_chat/muse-glimmer:30b"
        aidermacs-default-chat-mode 'code
        aidermacs-extra-args '("--no-show-model-warnings")
        )
  :custom
  ;; Keep changes explicit, no auto-commits by default
  (aidermacs-auto-commits nil)
  (aidermacs-show-diff-after-change t)
  (aidermacs-backend 'comint))

(provide 'config-llm)
;;; config-llm.el ends here
