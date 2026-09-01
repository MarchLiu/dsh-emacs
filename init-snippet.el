;; ---- dsh-emacs: DeepSeek Harness 的 Emacs 客户端 ----
;; 把本文件内容追加到 ~/.emacs 末尾即可，或执行：
;;   cat ~/jobs/dsh-eui/dsh-emacs/init-snippet.el >> ~/.emacs

(when (file-directory-p "~/jobs/dsh-eui/dsh-emacs")
  (add-to-list 'load-path "~/jobs/dsh-eui/dsh-emacs")
  (require 'dsh-emacs nil t)
  (require 'dsh-eval nil t)
  ;; 连接正在运行的 DSH web host（默认 127.0.0.1:3080）
  ;; M-x dsh 打开会话浏览器；会话 buffer 里 RET 发送、TAB 折叠工具输出、c 取消
  ;; AI -> Emacs eval 网关：允许 AI 通过 ~/jobs/dsh-eui/dsh-emacs/bin/dsh-eval
  ;; 在本 Emacs 内直接执行 elisp（免重启）。权限策略：
  ;;   safe     只读/纯函数自动执行；change 需在 Emacs 里 y/n 确认；
  ;;   all      除 danger 外自动执行（danger 始终确认，除非另调
  ;;            dsh-eval-danger-always-confirm）。
  (when (fboundp 'dsh-eval-server-ensure)
    (setq dsh-eval-allow-level 'confirm)   ; 可按需改为 'all
    (add-hook 'after-init-hook #'dsh-eval-server-ensure))
  )
