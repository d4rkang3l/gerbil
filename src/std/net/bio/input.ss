;;; -*- Gerbil -*-
;;; (C) vyzo at hackzen.org
;;; extensible binary i/o buffers with port compatible interface
;;; Warning: Low level unsafe interface; let their be Dragons.
package: std/net/bio

(import :gerbil/gambit/bits
        :std/error)
(export #t)

(declare (not safe))

;;; Input buffers
;;; e: u8vector
;;; rlo: read range low mark, where the next read can begin
;;; rhi: read range hi mark, where the read must end
;;; fill: lambda (buf need) => fixnum?
;;;       fill the buffer with need bytes in read range
;;; read: lambda (bytes start end buf) => fixnum?
;;;       read unbuffered
;;;       precondition: buffer is empty
(defstruct input-buffer (e rlo rhi fill read)
  unchecked: #t)

(def (bio-input-fill! buf need)
  ((&input-buffer-fill buf) buf need))

(def (bio-input-read bytes start end buf)
  ((&input-buffer-read buf) bytes start end buf))

(def (bio-read-u8 buf)
  (let ((rlo (&input-buffer-rlo buf))
        (rhi (&input-buffer-rhi buf)))
    (if (##fx< rlo rhi)
      (let (u8 (##u8vector-ref (&input-buffer-e buf) rlo))
        (set! (&input-buffer-rlo buf)
          (##fx+ rlo 1))
        u8)
      (let (rd (bio-input-fill! buf 1))
        (if (##fxzero? rd)
          (eof-object)
          (let* ((rlo (&input-buffer-rlo buf))
                 (u8 (##u8vector-ref (&input-buffer-e buf) rlo)))
            (set! (&input-buffer-rlo buf)
              (##fx+ rlo 1))
            u8))))))

(def (bio-peek-u8 buf)
  (let ((rlo (&input-buffer-rlo buf))
        (rhi (&input-buffer-rhi buf)))
    (if (##fx< rlo rhi)
      (##u8vector-ref (&input-buffer-e buf) rlo)
      (let (rd (bio-input-fill! buf 1))
        (if (##fxzero? rd)
          (eof-object)
          (let (rlo (&input-buffer-rlo buf))
            (##u8vector-ref (&input-buffer-e buf) rlo)))))))

(def (bio-read-subu8vector bytes start end buf)
  (let* ((rlo (&input-buffer-rlo buf))
         (rhi (&input-buffer-rhi buf))
         (need (##fx- end start))
         (rlo+need (##fx+ rlo need)))
    (cond
     ((##fx<= rlo+need rhi)             ; have all
      (##subu8vector-move! (&input-buffer-e buf) rlo rlo+need bytes start)
      (set! (&input-buffer-rlo buf)
        rlo+need)
      need)
     ((##fx< rlo rhi)                   ; have some
      (##subu8vector-move! (&input-buffer-e buf) rlo rhi bytes start)
      (set! (&input-buffer-rlo buf)
        rhi)
      (let* ((have (##fx- rhi rlo))
             (need (##fx- need have)))
        ;; does it make sense to buffer?
        (if (##fx< need (##u8vector-length (&input-buffer-e buf)))
          (let (rd (bio-input-fill! buf need))
            (if (##fx> rd 0)
              (##fx+ have (bio-read-subu8vector bytes (##fx+ start have) end buf))
              have))
          (##fx+ have (bio-input-read bytes (##fx+ start have) end buf)))))
     ;; have none, does it make sense to buffer?
     ((##fx< need (##u8vector-length (&input-buffer-e buf)))
      (let (rd (bio-input-fill! buf need))
        (if (##fx> rd 0)
          (bio-read-subu8vector bytes start end buf)
          0)))
     ;; read unbuffered
     (else
      (bio-input-read bytes start end buf)))))

(def (bio-read-subu8vector* bytes start end buf)
  (let* ((rlo  (&input-buffer-rlo buf))
         (rhi  (&input-buffer-rhi buf))
         (have (##fx- rhi rlo))
         (want (##fx- end start))
         (copy (##fxmin want have)))
    (when (##fx> copy 0)
      (let (rlo+copy (##fx+ rlo copy))
        (##subu8vector-move! (&input-buffer-e buf) rlo rlo+copy bytes start)
        (set! (&input-buffer-rlo buf)
          rlo+copy)))
    copy))

(def (bio-read-subu8vector-unbuffered bytes start end buf)
  (let* ((need (##fx- end start))
         (rlo (&input-buffer-rlo buf))
         (rhi (&input-buffer-rhi buf))
         (rlo+need (##fx+ rlo need)))
    (cond
     ((##fx<= rlo+need rhi)             ; have all
      (##subu8vector-move! (&input-buffer-e buf) rlo rlo+need bytes start)
      (set! (&input-buffer-rlo buf)
        rlo+need)
      need)
     ((##fx< rlo rhi)                   ; have some
      (let (have (##fx- rhi rlo))
        (##subu8vector-move! (&input-buffer-e buf) rlo rhi bytes start)
        (set! (&input-buffer-rlo buf)
          rhi)
        (##fx+ have (bio-input-read bytes (##fx+ start have) end buf))))
     (else                              ; have none
      (bio-input-read bytes start end buf)))))

(def (bio-read-bytes bytes buf)
  (let* ((len (u8vector-length bytes))
         (rd (bio-read-subu8vector bytes 0 len buf)))
    (unless (##fx= rd len)
      (raise-io-error 'bio-read-bytes "premature end of input" buf rd len))))

(def (bio-read-bytes-unbuffered bytes buf)
  (let* ((len (u8vector-length bytes))
         (rd (bio-read-subu8vector-unbuffered bytes 0 len buf)))
    (unless (##fx= rd len)
      (raise-io-error 'bio-read-bytes "premature end of input" buf rd len))))

(def (bio-read-u32 buf)
  (let* ((rlo (&input-buffer-rlo buf))
         (rhi (&input-buffer-rhi buf))
         (rlo+4 (##fx+ rlo 4)))
    (if (##fx<= rlo+4 rhi)
      (let (u32 (bio-get-u32 (&input-buffer-e buf) rlo))
        (set! (&input-buffer-rlo buf)
          rlo+4)
        u32)
      (let* ((_ (bio-input-fill! buf 4))
             (rlo (&input-buffer-rlo buf))
             (rhi (&input-buffer-rhi buf))
             (rlo+4 (##fx+ rlo 4)))
        (if (##fx<= rlo+4 rhi)
          (let (u32 (bio-get-u32 (&input-buffer-e buf) rlo))
            (set! (&input-buffer-rlo buf)
              rlo+4)
            u32)
          (raise-io-error 'bio-read-u32 "Premature end of input" buf rlo rhi))))))

(def (bio-get-u32 u8v start)
  (cond
   ((##fxarithmetic-shift-left? (##u8vector-ref u8v start) 24)
    => (lambda (bits)
         (##fxior bits
                  (##fxarithmetic-shift-left (##u8vector-ref u8v (##fx+ start 1)) 16)
                  (##fxarithmetic-shift-left (##u8vector-ref u8v (##fx+ start 2)) 8)
                  (##u8vector-ref u8v (##fx+ start 3)))))
   (else
    (bitwise-ior (arithmetic-shift (##u8vector-ref u8v start) 24)
                 (##fxarithmetic-shift-left (##u8vector-ref u8v (##fx+ start 1)) 16)
                 (##fxarithmetic-shift-left (##u8vector-ref u8v (##fx+ start 2)) 8)
                 (##u8vector-ref u8v (##fx+ start 3))))))

(def (bio-input-skip count buf)
  (let lp ((count count))
    (let* ((rlo (&input-buffer-rlo buf))
           (rhi (&input-buffer-rhi buf))
           (have (##fx- rhi rlo)))
      (if (##fx< have count)
        (let (need (##fx- count have))
          (set! (&input-buffer-rlo buf)
            rhi)
          (let (rd (bio-input-fill! buf need))
            (if (##fxzero? rd)
              (raise-io-error 'bio-input-skip "premature end of input" buf count)
              (lp need))))
        (let (rlo+count (##fx+ rlo count))
          (set! (&input-buffer-rlo buf)
            rlo+count))))))
