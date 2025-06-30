;; Handles governance functionality for staked STX

;; Add error constants
(define-constant ERR_NOT_ENOUGH_STAKE (err u200))
(define-constant ERR_PROPOSAL_NOT_ACTIVE (err u201))
(define-constant ERR_ALREADY_VOTED (err u202))
(define-constant ERR_INVALID_INPUT (err u203))
(define-constant ERR_INVALID_POOL (err u204))

(define-constant MIN_PROPOSAL_STAKE u100000000) ;; 100 STX

(define-map proposals
    uint ;; proposal ID
    {
        creator: principal,
        description: (string-utf8 256),
        votes-for: uint,
        votes-against: uint,
        active: bool,
        executed: bool,
    }
)

(define-map votes
    {
        proposal-id: uint,
        voter: principal,
    }
    bool
)

(define-data-var proposal-count uint u0)

(define-trait pool-trait (
    (get-stake-balance
        (principal)
        (response uint uint)
    )
))

(define-public (create-proposal
        (description (string-utf8 256))
        (pool-contract <pool-trait>)
    )
    (let ((stake-balance (try! (contract-call? pool-contract get-stake-balance tx-sender))))
        ;; Validate inputs
        (asserts! (> stake-balance MIN_PROPOSAL_STAKE) ERR_NOT_ENOUGH_STAKE)
        (let (
                (checked-description (unwrap! (as-max-len? description u256) ERR_INVALID_INPUT))
                (proposal-id (var-get proposal-count))
            )
            (map-set proposals proposal-id {
                creator: tx-sender,
                description: checked-description,
                votes-for: u0,
                votes-against: u0,
                active: true,
                executed: false,
            })
            (var-set proposal-count (+ proposal-id u1))
            (ok proposal-id)
        )
    )
)

(define-public (vote
        (pool-contract <pool-trait>)
        (proposal-id uint)
        (vote-for bool)
    )
    (let (
            (proposal (unwrap! (map-get? proposals proposal-id) ERR_PROPOSAL_NOT_ACTIVE))
            (stake-weight (try! (contract-call? pool-contract get-stake-balance tx-sender)))
        )
        (asserts! (get active proposal) ERR_PROPOSAL_NOT_ACTIVE)
        (asserts!
            (is-none (map-get? votes {
                proposal-id: proposal-id,
                voter: tx-sender,
            }))
            ERR_ALREADY_VOTED
        )
        (map-set votes {
            proposal-id: proposal-id,
            voter: tx-sender,
        }
            vote-for
        )
        (if vote-for
            (map-set proposals proposal-id
                (merge proposal { votes-for: (+ (get votes-for proposal) stake-weight) })
            )
            (map-set proposals proposal-id
                (merge proposal { votes-against: (+ (get votes-against proposal) stake-weight) })
            )
        )
        (ok true)
    )
)

(define-read-only (get-proposal (proposal-id uint))
    (map-get? proposals proposal-id)
)
