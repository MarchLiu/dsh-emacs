;; ---- dsh-emacs: DeepSeek Harness 的 Emacs 客户端 ----
;; 把本文件内容追加到 ~/.emacs 末尾即可，或执行：
;;   cat ~/jobs/dsh-eui/dsh-emacs/init-snippet.el >> ~/.emacs

(when (file-directory-p "~/jobs/dsh-eui/dsh-emacs")
  (add-to-list 'load-path "~/jobs/dsh-eui/dsh-emacs")
  (require 'dsh-emacs nil t)
  ;; 连接正在运行的 DSH web host（默认 127.0.0.1:3080）
  ;; M-x dsh 打开会话浏览器；会话 buffer 里 RET 发送、TAB 折叠工具输出、c 取消
  )
