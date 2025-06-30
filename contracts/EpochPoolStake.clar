;; Define trait for external contract
(define-trait epoch-rewards-trait (
    (start-new-epoch
        ()
        (response bool uint)
    )
))

(define-fungible-token stSTX)
(define-data-var total-staked uint u0)
(define-data-var epoch-length uint u144) ;; ~1 day in blocks
(define-data-var last-epoch-block uint u0)
(define-data-var cooldown-blocks uint u144) ;; 1 day cooldown
(define-data-var paused bool false)
(define-data-var contract-owner principal tx-sender)

(define-map staker-balances
    principal
    uint
)
(define-map unstaking-requests
    principal
    {
        amount: uint,
        unlock-height: uint,
    }
)

(define-map reward-claims
    {
        staker: principal,
        epoch: uint,
    }
    bool
)
(define-data-var total-rewards-distributed uint u0)

(define-map delegations
    principal
    principal
)

;; staker -> delegate

;; Stake STX and receive stSTX 
(define-public (stake (amount uint))
    (begin
        (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
        (var-set total-staked (+ (var-get total-staked) amount))
        (map-set staker-balances tx-sender
            (+ (default-to u0 (map-get? staker-balances tx-sender)) amount)
        )
        (try! (ft-mint? stSTX amount tx-sender))
        (ok true)
    )
)

;; Unstake STX by burning stSTX
(define-public (unstake (amount uint))
    (begin
        (try! (ft-burn? stSTX amount tx-sender))
        (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))
        (var-set total-staked (- (var-get total-staked) amount))
        (map-set staker-balances tx-sender
            (- (unwrap! (map-get? staker-balances tx-sender) (err u1)) amount)
        )
        (ok true)
    )
)

;; Request to unstake STX, with a cooldown period
(define-public (request-unstake (amount uint))
    (let (
            (unlock-height (+ stacks-block-height (var-get cooldown-blocks)))
            (current-block stacks-block-height)
            (next-epoch (+ (var-get last-epoch-block) (var-get epoch-length)))
        )
        (begin
            (try! (ft-burn? stSTX amount tx-sender))
            (map-set unstaking-requests tx-sender {
                amount: amount,
                unlock-height: unlock-height,
            })
            (ok true)
        )
    )
)

;; Read-only functions
(define-read-only (get-stake-balance (staker principal))
    (default-to u0 (map-get? staker-balances staker))
)

(define-read-only (get-total-staked)
    (var-get total-staked)
)

(define-public (set-paused (new-paused bool))
    (begin
        (asserts! (is-eq tx-sender (var-get contract-owner)) (err u403))
        (var-set paused new-paused)
        (ok true)
    )
)

(define-public (claim-rewards (epoch uint))
    (let ((has-claimed (default-to false
            (map-get? reward-claims {
                staker: tx-sender,
                epoch: epoch,
            })
        )))
        (asserts! (not has-claimed) (err u100))
        ;; Calculate and distribute rewards
        (ok true)
    )
)

(define-public (delegate-stake (delegate-to principal))
    (begin
        (map-set delegations tx-sender delegate-to)
        (ok true)
    )
)

(define-public (check-epoch (epoch-rewards-contract <epoch-rewards-trait>))
    (let (
            (current-block stacks-block-height)
            (next-epoch (+ (var-get last-epoch-block) (var-get epoch-length)))
        )
        (if (>= current-block next-epoch)
            (begin
                (var-set last-epoch-block current-block)
                (contract-call? epoch-rewards-contract start-new-epoch)
            )
            (ok false)
        )
    )
)
