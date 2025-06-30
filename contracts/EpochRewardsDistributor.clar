;; Handles reward distribution for staked STX

;; Define constants for error codes
(define-constant ERR_UNAUTHORIZED (err u100))
(define-constant ERR_REWARD_TRANSFER_FAILED (err u101))
(define-constant ERR_INVALID_AMOUNT (err u102))
(define-constant ERR_INVALID_SHARE (err u103))

(define-data-var epoch-rewards uint u0)
(define-data-var current-epoch uint u0)
(define-data-var rewards-per-cycle uint u0)

;; Only callable by EpochPoolStake contract
(define-public (add-rewards (amount uint))
    (begin
        (asserts! (is-eq contract-caller .EpochPoolStake) ERR_UNAUTHORIZED)
        (asserts! (> amount u0) ERR_INVALID_AMOUNT)
        ;; Update rewards safely
        (var-set epoch-rewards (+ (var-get epoch-rewards) amount))
        (ok true)
    )
)

(define-public (distribute-rewards
        (staker principal)
        (share uint)
    )
    (begin
        (asserts! (is-eq contract-caller .EpochPoolStake) ERR_UNAUTHORIZED)
        (asserts! (<= share u100000000) ERR_INVALID_SHARE) ;; Max 100%
        (let ((reward-amount (/ (* (var-get epoch-rewards) share) u100000000)))
            (asserts! (> reward-amount u0) ERR_INVALID_AMOUNT)
            (try! (as-contract (stx-transfer? reward-amount tx-sender staker)))
            (ok reward-amount)
        )
    )
)

(define-public (start-new-epoch)
    (begin
        (asserts! (is-eq contract-caller .EpochPoolStake) ERR_UNAUTHORIZED)
        (var-set current-epoch (+ (var-get current-epoch) u1))
        (var-set epoch-rewards u0)
        (ok (var-get current-epoch))
    )
)
