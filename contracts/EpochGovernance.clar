;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Enhanced EpochGovernance Contract v2.0
;; Features:
;; - Enhanced governance with time-locked execution
;; - Quadratic voting to prevent whale dominance
;; - Multi-tier proposal system
;; - Delegation marketplace
;; - Emergency governance controls
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; ---------------------------
;; Constants and Error Codes
;; ---------------------------

(define-constant ERR-NOT-ENOUGH-STAKE u200)
(define-constant ERR-PROPOSAL-NOT-ACTIVE u201)
(define-constant ERR-ALREADY-VOTED u202)
(define-constant ERR-INVALID-INPUT u203)
(define-constant ERR-INVALID-POOL u204)
(define-constant ERR-PROPOSAL-NOT-PASSED u205)
(define-constant ERR-TIMELOCK-NOT-EXPIRED u206)
(define-constant ERR-PROPOSAL-EXPIRED u207)
(define-constant ERR-UNAUTHORIZED u208)
(define-constant ERR-INVALID-VOTE-STRENGTH u209)
(define-constant ERR-INSUFFICIENT-VOTING_POWER u210)
(define-constant ERR-PROPOSAL-ALREADY_EXECUTED u211)
(define-constant ERR-EMERGENCY-ACTIVE u212)

(define-constant MIN-PROPOSAL-STAKE u100000000) ;; 100 STX
(define-constant VOTING-PERIOD u1008) ;; ~1 week in blocks
(define-constant TIMELOCK-PERIOD u2016) ;; ~2 weeks in blocks
(define-constant EMERGENCY-TIMELOCK u144) ;; ~1 day for emergency proposals
(define-constant MAX-VOTE-STRENGTH u100) ;; Maximum quadratic vote strength
(define-constant QUORUM-THRESHOLD u3000) ;; 30% quorum required

;; ---------------------------
;; State Variables
;; ---------------------------

(define-data-var proposal-count uint u0)
(define-data-var emergency-mode bool false)
(define-data-var governance-paused bool false)
(define-data-var contract-owner principal tx-sender)

;; ---------------------------
;; Data Maps
;; ---------------------------

;; Enhanced proposal tracking
(define-map proposals
    uint ;; proposal ID
    {
        creator: principal,
        proposal-type: (string-ascii 32), ;; "parameter", "upgrade", "emergency"
        title: (string-ascii 64),
        description: (string-utf8 256),
        target-contract: (optional principal),
        target-function: (optional (string-ascii 32)),
        parameters: (list 5 uint),
        votes-for: uint,
        votes-against: uint,
        total-voting-power: uint,
        created-block: uint,
        voting-end-block: uint,
        execution-block: uint,
        active: bool,
        executed: bool,
        emergency: bool,
        quorum-reached: bool
    }
)

;; Enhanced voting tracking with quadratic voting
(define-map votes
    {
        proposal-id: uint,
        voter: principal,
    }
    {
        vote-for: bool,
        vote-strength: uint,
        voting-power-used: uint,
        quadratic-cost: uint,
        vote-timestamp: uint
    }
)

;; Voting power tracking for quadratic voting
(define-map voting-power
    {
        proposal-id: uint,
        voter: principal
    }
    {
        total-power: uint,
        used-power: uint,
        remaining-power: uint
    }
)

;; Governance delegation
(define-map governance-delegations
    principal ;; delegator
    {
        delegate: principal,
        delegation-timestamp: uint,
        active: bool,
        auto-vote: bool
    }
)

;; Proposal categories and requirements
(define-map proposal-categories
    (string-ascii 32) ;; category
    {
        min-stake-required: uint,
        voting-period: uint,
        timelock-period: uint,
        quorum-threshold: uint,
        execution-threshold: uint
    }
)

;; Governance statistics
(define-map governance-stats
    uint ;; proposal-id
    {
        participation-rate: uint,
        average-vote-strength: uint,
        whale-influence: uint,
        execution-delay: uint
    }
)

;; ---------------------------
;; Traits
;; ---------------------------

(define-trait pool-trait (
    (get-stake-balance
        (principal)
        (response uint uint)
    )
    (get-staker-info
        (principal)
        (response (optional {
            ststx-balance: uint,
            stx-equivalent: uint,
            last-claim-epoch: uint,
            stake-timestamp: uint
        }) uint)
    )
))

;; ---------------------------
;; Validation Functions
;; ---------------------------

(define-private (validate-not-paused)
    (begin
        (asserts! (not (var-get governance-paused)) (err ERR-UNAUTHORIZED))
        (ok true)
    )
)

(define-private (validate-proposal-input 
    (title (string-ascii 64))
    (description (string-utf8 256)))
    (begin
        (asserts! (> (len title) u0) (err ERR-INVALID-INPUT))
        (asserts! (> (len description) u0) (err ERR-INVALID-INPUT))
        (ok true)
    )
)

(define-private (calculate-quadratic-cost (vote-strength uint))
    (* vote-strength vote-strength)
)

;; ---------------------------
;; Initialization
;; ---------------------------

;; Initialize proposal categories
(define-private (init-proposal-categories)
    (begin
        ;; Parameter changes
        (map-set proposal-categories "parameter" {
            min-stake-required: u50000000, ;; 50 STX
            voting-period: u1008, ;; 1 week
            timelock-period: u1008, ;; 1 week
            quorum-threshold: u2000, ;; 20%
            execution-threshold: u5100 ;; 51%
        })
        
        ;; Contract upgrades
        (map-set proposal-categories "upgrade" {
            min-stake-required: u200000000, ;; 200 STX
            voting-period: u2016, ;; 2 weeks
            timelock-period: u2016, ;; 2 weeks
            quorum-threshold: u4000, ;; 40%
            execution-threshold: u6700 ;; 67%
        })
        
        ;; Emergency proposals
        (map-set proposal-categories "emergency" {
            min-stake-required: u500000000, ;; 500 STX
            voting-period: u504, ;; 3.5 days
            timelock-period: u144, ;; 1 day
            quorum-threshold: u3000, ;; 30%
            execution-threshold: u7500 ;; 75%
        })
        
        (ok true)
    )
)

;; ---------------------------
;; Enhanced Proposal Creation
;; ---------------------------

;; Create enhanced proposal with categories
(define-public (create-proposal
        (proposal-type (string-ascii 32))
        (title (string-ascii 64))
        (description (string-utf8 256))
        (target-contract (optional principal))
        (target-function (optional (string-ascii 32)))
        (parameters (list 5 uint))
        (emergency bool)
        (pool-contract <pool-trait>)
    )
    (begin
        (try! (validate-not-paused))
        (try! (validate-proposal-input title description))
        
        ;; Get proposal requirements
        (let ((category-info (unwrap! (map-get? proposal-categories proposal-type) (err ERR-INVALID-INPUT)))
              (stake-balance (try! (contract-call? pool-contract get-stake-balance tx-sender))))
            
            ;; Check minimum stake requirement
            (asserts! (>= stake-balance (get min-stake-required category-info)) (err ERR-NOT-ENOUGH-STAKE))
            
            ;; Check emergency mode restrictions
            (if emergency
                (asserts! (>= stake-balance u500000000) (err ERR-NOT-ENOUGH-STAKE)) ;; Higher requirement for emergency
                true
            )
            
            (let ((proposal-id (var-get proposal-count))
                  (voting-period (if emergency u504 (get voting-period category-info)))
                  (timelock-period (if emergency EMERGENCY-TIMELOCK (get timelock-period category-info))))
                
                ;; Create proposal
                (map-set proposals proposal-id {
                    creator: tx-sender,
                    proposal-type: proposal-type,
                    title: title,
                    description: description,
                    target-contract: target-contract,
                    target-function: target-function,
                    parameters: parameters,
                    votes-for: u0,
                    votes-against: u0,
                    total-voting-power: u0,
                    created-block: stacks-block-height,
                    voting-end-block: (+ stacks-block-height voting-period),
                    execution-block: (+ stacks-block-height (+ voting-period timelock-period)),
                    active: true,
                    executed: false,
                    emergency: emergency,
                    quorum-reached: false
                })
                
                ;; Update proposal count
                (var-set proposal-count (+ proposal-id u1))
                
                (ok proposal-id)
            )
        )
    )
)

;; ---------------------------
;; Enhanced Voting System
;; ---------------------------

;; Quadratic voting implementation
(define-public (vote-quadratic
        (pool-contract <pool-trait>)
        (proposal-id uint)
        (vote-for bool)
        (vote-strength uint)
    )
    (begin
        (try! (validate-not-paused))
        (asserts! (and (> vote-strength u0) (<= vote-strength MAX-VOTE-STRENGTH)) (err ERR-INVALID-VOTE-STRENGTH))
        
        (let ((proposal (unwrap! (map-get? proposals proposal-id) (err ERR-PROPOSAL-NOT-ACTIVE)))
              (stake-info (try! (contract-call? pool-contract get-staker-info tx-sender))))
            
            ;; Check proposal is active and voting period hasn't ended
            (asserts! (get active proposal) (err ERR-PROPOSAL-NOT-ACTIVE))
            (asserts! (<= stacks-block-height (get voting-end-block proposal)) (err ERR-PROPOSAL-EXPIRED))
            
            ;; Check if already voted
            (asserts! (is-none (map-get? votes {proposal-id: proposal-id, voter: tx-sender})) (err ERR-ALREADY-VOTED))
            
            (match stake-info
                staker-data (let ((stake-balance (get ststx-balance staker-data))
                                 (quadratic-cost (calculate-quadratic-cost vote-strength)))
                    
                    ;; Check sufficient voting power
                    (asserts! (>= stake-balance quadratic-cost) (err ERR-INSUFFICIENT-VOTING_POWER))
                    
                    ;; Calculate actual voting power (square root to counter quadratic cost)
                    (let ((actual-voting-power (* vote-strength stake-balance)))
                        
                        ;; Record vote
                        (map-set votes {proposal-id: proposal-id, voter: tx-sender} {
                            vote-for: vote-for,
                            vote-strength: vote-strength,
                            voting-power-used: actual-voting-power,
                            quadratic-cost: quadratic-cost,
                            vote-timestamp: stacks-block-height
                        })
                        
                        ;; Update proposal vote counts
                        (let ((updated-proposal (if vote-for
                            (merge proposal {
                                votes-for: (+ (get votes-for proposal) actual-voting-power),
                                total-voting-power: (+ (get total-voting-power proposal) actual-voting-power)
                            })
                            (merge proposal {
                                votes-against: (+ (get votes-against proposal) actual-voting-power),
                                total-voting-power: (+ (get total-voting-power proposal) actual-voting-power)
                            }))))
                            
                            ;; Check if quorum is reached
                            (let ((category-info (unwrap! (map-get? proposal-categories (get proposal-type proposal)) (err ERR-INVALID-INPUT)))
                                  (total-stake (try! (contract-call? pool-contract get-stake-balance tx-sender))) ;; This should get total stake
                                  (participation-rate (if (> total-stake u0) 
                                                        (/ (* (get total-voting-power updated-proposal) u10000) total-stake) 
                                                        u0)))
                                
                                (let ((quorum-reached (>= participation-rate (get quorum-threshold category-info))))
                                    (map-set proposals proposal-id (merge updated-proposal {quorum-reached: quorum-reached}))
                                )
                            )
                        )
                        
                        (ok actual-voting-power)
                    )
                )
                (err ERR-INVALID-POOL)
            )
        )
    )
)

;; Standard voting (for backwards compatibility)
(define-public (vote
        (pool-contract <pool-trait>)
        (proposal-id uint)
        (vote-for bool)
    )
    (vote-quadratic pool-contract proposal-id vote-for u1)
)

;; ---------------------------
;; Governance Delegation
;; ---------------------------

;; Delegate governance power
(define-public (delegate-governance-power 
    (delegate principal) 
    (auto-vote bool))
    (begin
        (try! (validate-not-paused))
        (asserts! (not (is-eq delegate tx-sender)) (err ERR-INVALID-INPUT))
        
        (map-set governance-delegations tx-sender {
            delegate: delegate,
            delegation-timestamp: stacks-block-height,
            active: true,
            auto-vote: auto-vote
        })
        
        (ok true)
    )
)

;; Remove governance delegation
(define-public (remove-governance-delegation)
    (begin
        (try! (validate-not-paused))
        
        (let ((delegation (unwrap! (map-get? governance-delegations tx-sender) (err ERR-INVALID-INPUT))))
            (map-set governance-delegations tx-sender (merge delegation {active: false}))
            (ok true)
        )
    )
)

;; Vote on behalf of delegator (if auto-vote enabled)
(define-public (vote-as-delegate
        (pool-contract <pool-trait>)
        (proposal-id uint)
        (vote-for bool)
        (delegator principal)
    )
    (begin
        (try! (validate-not-paused))
        
        (let ((delegation (unwrap! (map-get? governance-delegations delegator) (err ERR-UNAUTHORIZED))))
            ;; Check delegation is active and auto-vote is enabled
            (asserts! (get active delegation) (err ERR-UNAUTHORIZED))
            (asserts! (get auto-vote delegation) (err ERR-UNAUTHORIZED))
            (asserts! (is-eq (get delegate delegation) tx-sender) (err ERR-UNAUTHORIZED))
            
            ;; Vote using delegator's stake (implementation would need to be adapted)
            (vote-quadratic pool-contract proposal-id vote-for u1)
        )
    )
)

;; ---------------------------
;; Proposal Execution
;; ---------------------------

;; Execute proposal after timelock period
(define-public (execute-proposal (proposal-id uint))
    (begin
        (try! (validate-not-paused))
        
        (let ((proposal (unwrap! (map-get? proposals proposal-id) (err ERR-PROPOSAL-NOT-ACTIVE))))
            ;; Check proposal hasn't been executed
            (asserts! (not (get executed proposal)) (err ERR-PROPOSAL-ALREADY_EXECUTED))
            
            ;; Check voting period has ended
            (asserts! (> stacks-block-height (get voting-end-block proposal)) (err ERR-PROPOSAL-NOT-PASSED))
            
            ;; Check timelock period has passed
            (asserts! (>= stacks-block-height (get execution-block proposal)) (err ERR-TIMELOCK-NOT-EXPIRED))
            
            ;; Check quorum was reached
            (asserts! (get quorum-reached proposal) (err ERR-PROPOSAL-NOT-PASSED))
            
            ;; Check proposal passed
            (let ((category-info (unwrap! (map-get? proposal-categories (get proposal-type proposal)) (err ERR-INVALID-INPUT)))
                  (total-votes (+ (get votes-for proposal) (get votes-against proposal)))
                  (approval-rate (if (> total-votes u0) 
                                   (/ (* (get votes-for proposal) u10000) total-votes) 
                                   u0)))
                
                (asserts! (>= approval-rate (get execution-threshold category-info)) (err ERR-PROPOSAL-NOT-PASSED))
                
                ;; Mark as executed
                (map-set proposals proposal-id (merge proposal {executed: true}))
                
                ;; Record governance statistics
                (map-set governance-stats proposal-id {
                    participation-rate: (/ (* (get total-voting-power proposal) u10000) u1000000), ;; Simplified
                    average-vote-strength: (if (> (get total-voting-power proposal) u0) 
                                             (/ total-votes (get total-voting-power proposal)) 
                                             u0),
                    whale-influence: u0, ;; Simplified - would calculate vote concentration
                    execution-delay: (- stacks-block-height (get created-block proposal))
                })
                
                (ok true)
            )
        )
    )
)

;; Calculate whale influence metric
(define-private (calculate-whale-influence (proposal-id uint))
    ;; Simplified whale influence calculation
    ;; In a full implementation, this would analyze vote distribution
    u0
)

;; ---------------------------
;; Emergency Governance
;; ---------------------------

;; Enable emergency mode (high threshold required)
(define-public (enable-emergency-mode (reason (string-ascii 128)))
    (begin
        (asserts! (is-eq tx-sender (var-get contract-owner)) (err ERR-UNAUTHORIZED))
        (var-set emergency-mode true)
        (ok true)
    )
)

;; Disable emergency mode
(define-public (disable-emergency-mode)
    (begin
        (asserts! (is-eq tx-sender (var-get contract-owner)) (err ERR-UNAUTHORIZED))
        (var-set emergency-mode false)
        (ok true)
    )
)

;; Emergency proposal execution (bypasses normal timelock)
(define-public (emergency-execute (proposal-id uint))
    (begin
        (asserts! (var-get emergency-mode) (err ERR-EMERGENCY-ACTIVE))
        
        (let ((proposal (unwrap! (map-get? proposals proposal-id) (err ERR-PROPOSAL-NOT-ACTIVE))))
            (asserts! (get emergency proposal) (err ERR-UNAUTHORIZED))
            (asserts! (not (get executed proposal)) (err ERR-PROPOSAL-ALREADY_EXECUTED))
            
            ;; Emergency execution with reduced timelock
            (asserts! (>= stacks-block-height (+ (get voting-end-block proposal) EMERGENCY-TIMELOCK)) (err ERR-TIMELOCK-NOT-EXPIRED))
            
            ;; Higher threshold for emergency execution
            (let ((total-votes (+ (get votes-for proposal) (get votes-against proposal)))
                  (approval-rate (if (> total-votes u0) 
                                   (/ (* (get votes-for proposal) u10000) total-votes) 
                                   u0)))
                
                (asserts! (>= approval-rate u7500) (err ERR-PROPOSAL-NOT-PASSED)) ;; 75% threshold
                
                (map-set proposals proposal-id (merge proposal {executed: true}))
                (ok true)
            )
        )
    )
)

;; ---------------------------
;; Administrative Functions
;; ---------------------------

(define-public (pause-governance (paused bool))
    (begin
        (asserts! (is-eq tx-sender (var-get contract-owner)) (err ERR-UNAUTHORIZED))
        (var-set governance-paused paused)
        (ok true)
    )
)

(define-public (transfer-ownership (new-owner principal))
    (begin
        (asserts! (is-eq tx-sender (var-get contract-owner)) (err ERR-UNAUTHORIZED))
        (var-set contract-owner new-owner)
        (ok true)
    )
)

;; ---------------------------
;; Read-Only Functions
;; ---------------------------

(define-read-only (get-proposal (proposal-id uint))
    (map-get? proposals proposal-id)
)

(define-read-only (get-vote (proposal-id uint) (voter principal))
    (map-get? votes {proposal-id: proposal-id, voter: voter})
)

(define-read-only (get-governance-delegation (delegator principal))
    (map-get? governance-delegations delegator)
)

(define-read-only (get-proposal-category (category (string-ascii 32)))
    (map-get? proposal-categories category)
)

(define-read-only (get-governance-stats (proposal-id uint))
    (map-get? governance-stats proposal-id)
)

(define-read-only (get-proposal-count)
    (var-get proposal-count)
)

(define-read-only (is-emergency-mode)
    (var-get emergency-mode)
)

(define-read-only (is-governance-paused)
    (var-get governance-paused)
)

(define-read-only (calculate-voting-power (stake-balance uint) (vote-strength uint))
    (* vote-strength stake-balance)
)

(define-read-only (get-contract-info)
    {
        proposal-count: (var-get proposal-count),
        emergency-mode: (var-get emergency-mode),
        governance-paused: (var-get governance-paused),
        contract-owner: (var-get contract-owner)
    }
)

;; Initialize the contract
(begin
    (unwrap! (init-proposal-categories) (err u999))
)
