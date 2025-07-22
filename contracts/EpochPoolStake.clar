;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Enhanced EpochPoolStake Contract v2.0
;; Features:
;; - PoX Integration for Real Staking
;; - Dynamic Exchange Rate with Reward Compounding
;; - Enhanced Security and Validation
;; - Comprehensive Reward Management
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; Define trait for external contract
(define-trait epoch-rewards-trait (
    (start-new-epoch
        ()
        (response bool uint)
    )
))

;; Fungible token for liquid staking
(define-fungible-token stSTX)

;; ---------------------------
;; State Variables
;; ---------------------------

(define-data-var total-staked uint u0)
(define-data-var total-stx-value uint u0) ;; Total STX value including rewards
(define-data-var epoch-length uint u144) ;; ~1 day in blocks
(define-data-var last-epoch-block uint u0)
(define-data-var cooldown-blocks uint u144) ;; 1 day cooldown
(define-data-var paused bool false)
(define-data-var contract-owner principal tx-sender)
(define-data-var exchange-rate uint u1000000) ;; 1.0 in micro-units (1 STX = 1 stSTX initially)
(define-data-var accumulated-rewards uint u0)
(define-data-var total-rewards-distributed uint u0)
(define-data-var min-stake-amount uint u1000000) ;; 1 STX minimum
(define-data-var max-stake-amount uint u100000000000) ;; 100,000 STX maximum
(define-data-var current-pox-cycle uint u0)
(define-data-var next-unstake-id uint u1)

;; ---------------------------
;; Data Maps
;; ---------------------------

;; Enhanced staker tracking
(define-map staker-balances
    principal
    {
        ststx-balance: uint,
        stx-equivalent: uint,
        last-claim-epoch: uint,
        stake-timestamp: uint
    }
)

;; Enhanced unstaking requests with IDs
(define-map unstaking-requests
    uint ;; request-id
    {
        staker: principal,
        ststx-amount: uint,
        stx-amount: uint,
        unlock-height: uint,
        request-timestamp: uint,
        claimed: bool
    }
)

;; User unstaking request tracking
(define-map user-unstaking-requests
    principal
    (list 10 uint) ;; List of request IDs
)

;; PoX cycle tracking
(define-map pox-cycles
    uint ;; cycle-id
    {
        total-stacked: uint,
        rewards-earned: uint,
        participants: uint,
        start-block: uint,
        end-block: uint,
        reward-rate: uint
    }
)

;; Reward claims tracking
(define-map reward-claims
    {
        staker: principal,
        epoch: uint,
    }
    {
        claimed: bool,
        amount: uint,
        claim-timestamp: uint
    }
)

;; Delegation tracking
(define-map delegations
    principal
    {
        delegate-to: principal,
        delegation-timestamp: uint,
        active: bool
    }
)

;; Performance metrics
(define-map performance-metrics
    uint ;; timestamp
    {
        total-staked: uint,
        apy: uint,
        exchange-rate: uint,
        reward-rate: uint,
        active-stakers: uint
    }
)

;; ---------------------------
;; Constants and Error Codes
;; ---------------------------

(define-constant ERR-PAUSED u1)
(define-constant ERR-UNAUTHORIZED u2)
(define-constant ERR-INVALID-AMOUNT u3)
(define-constant ERR-INSUFFICIENT-BALANCE u4)
(define-constant ERR-ALREADY-CLAIMED u5)
(define-constant ERR-COOLDOWN-NOT-EXPIRED u6)
(define-constant ERR-REQUEST-NOT-FOUND u7)
(define-constant ERR-ALREADY-UNSTAKING u8)
(define-constant ERR-OVERFLOW u9)
(define-constant ERR-INVALID-EXCHANGE-RATE u10)
(define-constant ERR-POX-CYCLE-NOT-READY u11)
(define-constant ERR-DELEGATION-FAILED u12)

(define-constant MICRO-STX u1000000)
(define-constant MAX-UINT u340282366920938463463374607431768211455)
(define-constant REWARD-PRECISION u1000000000) ;; 9 decimal precision

;; ---------------------------
;; Validation Functions
;; ---------------------------

(define-private (validate-amount (amount uint))
    (begin
        (asserts! (>= amount (var-get min-stake-amount)) (err ERR-INVALID-AMOUNT))
        (asserts! (<= amount (var-get max-stake-amount)) (err ERR-INVALID-AMOUNT))
        (ok amount)
    )
)

(define-private (check-not-paused)
    (begin
        (asserts! (not (var-get paused)) (err ERR-PAUSED))
        (ok true)
    )
)

(define-private (check-overflow (a uint) (b uint))
    (let ((sum (+ a b)))
        (asserts! (>= sum a) (err ERR-OVERFLOW))
        (ok sum)
    )
)

(define-private (is-contract-owner)
    (is-eq tx-sender (var-get contract-owner))
)

;; ---------------------------
;; Exchange Rate Management
;; ---------------------------

;; Calculate dynamic exchange rate based on accumulated rewards
(define-private (calculate-exchange-rate)
    (let (
        (total-ststx-supply (ft-get-supply stSTX))
        (total-value (+ (var-get total-staked) (var-get accumulated-rewards)))
    )
    (if (> total-ststx-supply u0)
        (/ (* total-value MICRO-STX) total-ststx-supply)
        MICRO-STX
    )))

;; Update exchange rate and compound rewards
(define-public (update-exchange-rate)
    (begin
        (try! (check-not-paused))
        (let ((new-rate (calculate-exchange-rate)))
            (asserts! (> new-rate u0) (err ERR-INVALID-EXCHANGE-RATE))
            (var-set exchange-rate new-rate)
            (var-set total-stx-value (+ (var-get total-staked) (var-get accumulated-rewards)))
            (ok new-rate)
        )
    )
)

;; Convert STX to stSTX based on current exchange rate
(define-private (stx-to-ststx (stx-amount uint))
    (/ (* stx-amount MICRO-STX) (var-get exchange-rate))
)

;; Convert stSTX to STX based on current exchange rate
(define-private (ststx-to-stx (ststx-amount uint))
    (/ (* ststx-amount (var-get exchange-rate)) MICRO-STX)
)

;; ---------------------------
;; PoX Integration Functions
;; ---------------------------

;; Add rewards from PoX stacking
(define-public (add-pox-rewards (reward-amount uint))
    (begin
        (asserts! (is-contract-owner) (err ERR-UNAUTHORIZED))
        (try! (check-not-paused))
        (try! (validate-amount reward-amount))
        
        ;; Update accumulated rewards
        (var-set accumulated-rewards (+ (var-get accumulated-rewards) reward-amount))
        (var-set total-rewards-distributed (+ (var-get total-rewards-distributed) reward-amount))
        
        ;; Update exchange rate to reflect new rewards
        (try! (update-exchange-rate))
        
        ;; Record PoX cycle data
        (let ((current-cycle (var-get current-pox-cycle)))
            (map-set pox-cycles current-cycle {
                total-stacked: (var-get total-staked),
                rewards-earned: reward-amount,
                participants: (ft-get-supply stSTX), ;; Use total supply as participant count
                start-block: (var-get last-epoch-block),
                end-block: stacks-block-height,
                reward-rate: (if (> (var-get total-staked) u0) 
                              (/ (* reward-amount REWARD-PRECISION) (var-get total-staked)) 
                              u0)
            })
            (var-set current-pox-cycle (+ current-cycle u1))
        )
        
        (ok reward-amount)
    )
)

;; Start new PoX cycle
(define-public (start-pox-cycle)
    (begin
        (asserts! (is-contract-owner) (err ERR-UNAUTHORIZED))
        (try! (check-not-paused))
        
        (let ((current-cycle (var-get current-pox-cycle)))
            ;; Initialize new cycle
            (map-set pox-cycles current-cycle {
                total-stacked: (var-get total-staked),
                rewards-earned: u0,
                participants: u0,
                start-block: stacks-block-height,
                end-block: u0,
                reward-rate: u0
            })
            (ok current-cycle)
        )
    )
)

;; ---------------------------
;; Enhanced Staking Functions
;; ---------------------------

;; Stake STX and receive stSTX with dynamic exchange rate
(define-public (stake (amount uint))
    (begin
        (try! (check-not-paused))
        (try! (validate-amount amount))
        
        ;; Transfer STX to contract
        (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
        
        ;; Calculate stSTX amount based on current exchange rate
        (let ((ststx-amount (stx-to-ststx amount)))
            ;; Update total staked
            (var-set total-staked (try! (check-overflow (var-get total-staked) amount)))
            
            ;; Update user balance
            (let ((current-data (default-to {
                ststx-balance: u0,
                stx-equivalent: u0,
                last-claim-epoch: u0,
                stake-timestamp: stacks-block-height
            } (map-get? staker-balances tx-sender))))
                
                (map-set staker-balances tx-sender {
                    ststx-balance: (+ (get ststx-balance current-data) ststx-amount),
                    stx-equivalent: (+ (get stx-equivalent current-data) amount),
                    last-claim-epoch: (get last-claim-epoch current-data),
                    stake-timestamp: (if (is-eq (get ststx-balance current-data) u0) 
                                       stacks-block-height 
                                       (get stake-timestamp current-data))
                })
            )
            
            ;; Mint stSTX tokens
            (try! (ft-mint? stSTX ststx-amount tx-sender))
            
            ;; Update exchange rate
            (try! (update-exchange-rate))
            
            (ok ststx-amount)
        )
    )
)

;; Request to unstake STX with enhanced security
(define-public (request-unstake (ststx-amount uint))
    (begin
        (try! (check-not-paused))
        (asserts! (> ststx-amount u0) (err ERR-INVALID-AMOUNT))
        
        ;; Check user has sufficient stSTX balance
        (let ((user-data (unwrap! (map-get? staker-balances tx-sender) (err ERR-INSUFFICIENT-BALANCE))))
            (asserts! (>= (get ststx-balance user-data) ststx-amount) (err ERR-INSUFFICIENT-BALANCE))
            
            ;; Calculate STX amount to return
            (let ((stx-amount (ststx-to-stx ststx-amount))
                  (request-id (var-get next-unstake-id))
                  (unlock-height (+ stacks-block-height (var-get cooldown-blocks))))
                
                ;; Burn stSTX tokens
                (try! (ft-burn? stSTX ststx-amount tx-sender))
                
                ;; Update user balance
                (map-set staker-balances tx-sender {
                    ststx-balance: (- (get ststx-balance user-data) ststx-amount),
                    stx-equivalent: (get stx-equivalent user-data),
                    last-claim-epoch: (get last-claim-epoch user-data),
                    stake-timestamp: (get stake-timestamp user-data)
                })
                
                ;; Create unstaking request
                (map-set unstaking-requests request-id {
                    staker: tx-sender,
                    ststx-amount: ststx-amount,
                    stx-amount: stx-amount,
                    unlock-height: unlock-height,
                    request-timestamp: stacks-block-height,
                    claimed: false
                })
                
                ;; Add to user's request list
                (let ((user-requests (default-to (list) (map-get? user-unstaking-requests tx-sender))))
                    (map-set user-unstaking-requests tx-sender 
                        (unwrap! (as-max-len? (append user-requests request-id) u10) (err ERR-OVERFLOW)))
                )
                
                ;; Update next request ID
                (var-set next-unstake-id (+ request-id u1))
                
                (ok request-id)
            )
        )
    )
)

;; Complete unstaking after cooldown period
(define-public (complete-unstake (request-id uint))
    (begin
        (try! (check-not-paused))
        
        (let ((request (unwrap! (map-get? unstaking-requests request-id) (err ERR-REQUEST-NOT-FOUND))))
            ;; Verify request belongs to sender
            (asserts! (is-eq (get staker request) tx-sender) (err ERR-UNAUTHORIZED))
            
            ;; Check cooldown period has expired
            (asserts! (>= stacks-block-height (get unlock-height request)) (err ERR-COOLDOWN-NOT-EXPIRED))
            
            ;; Check not already claimed
            (asserts! (not (get claimed request)) (err ERR-ALREADY-CLAIMED))
            
            ;; Transfer STX back to user
            (try! (as-contract (stx-transfer? (get stx-amount request) tx-sender tx-sender)))
            
            ;; Update total staked
            (var-set total-staked (- (var-get total-staked) (get stx-amount request)))
            
            ;; Mark request as claimed
            (map-set unstaking-requests request-id (merge request {claimed: true}))
            
            ;; Update exchange rate
            (try! (update-exchange-rate))
            
            (ok (get stx-amount request))
        )
    )
)

;; Remove the insecure direct unstake function - force cooldown period

;; ---------------------------
;; Enhanced Reward Functions
;; ---------------------------

;; Claim rewards for a specific epoch with proper calculation
(define-public (claim-rewards (epoch uint))
    (begin
        (try! (check-not-paused))
        
        (let ((claim-key {staker: tx-sender, epoch: epoch})
              (has-claimed (default-to {claimed: false, amount: u0, claim-timestamp: u0} 
                           (map-get? reward-claims claim-key))))
            
            (asserts! (not (get claimed has-claimed)) (err ERR-ALREADY-CLAIMED))
            
            ;; Calculate user's share of rewards for the epoch
            (let ((user-data (unwrap! (map-get? staker-balances tx-sender) (err ERR-INSUFFICIENT-BALANCE)))
                  (pox-cycle-data (unwrap! (map-get? pox-cycles epoch) (err ERR-POX-CYCLE-NOT-READY))))
                
                (let ((user-share (if (> (get total-stacked pox-cycle-data) u0)
                                    (/ (* (get ststx-balance user-data) REWARD-PRECISION) 
                                       (get total-stacked pox-cycle-data))
                                    u0))
                      (reward-amount (/ (* (get rewards-earned pox-cycle-data) user-share) REWARD-PRECISION)))
                    
                    (asserts! (> reward-amount u0) (err ERR-INVALID-AMOUNT))
                    
                    ;; Transfer reward to user
                    (try! (as-contract (stx-transfer? reward-amount tx-sender tx-sender)))
                    
                    ;; Mark as claimed
                    (map-set reward-claims claim-key {
                        claimed: true,
                        amount: reward-amount,
                        claim-timestamp: stacks-block-height
                    })
                    
                    ;; Update user's last claim epoch
                    (map-set staker-balances tx-sender (merge user-data {
                        last-claim-epoch: epoch
                    }))
                    
                    (ok reward-amount)
                )
            )
        )
    )
)

;; ---------------------------
;; Enhanced Delegation Functions
;; ---------------------------

;; Delegate stake with enhanced tracking
(define-public (delegate-stake (delegate-to principal))
    (begin
        (try! (check-not-paused))
        (asserts! (not (is-eq delegate-to tx-sender)) (err ERR-DELEGATION-FAILED))
        
        ;; Check user has stake to delegate
        (let ((user-data (unwrap! (map-get? staker-balances tx-sender) (err ERR-INSUFFICIENT-BALANCE))))
            (asserts! (> (get ststx-balance user-data) u0) (err ERR-INSUFFICIENT-BALANCE))
            
            ;; Update delegation
            (map-set delegations tx-sender {
                delegate-to: delegate-to,
                delegation-timestamp: stacks-block-height,
                active: true
            })
            
            (ok true)
        )
    )
)

;; Remove delegation
(define-public (remove-delegation)
    (begin
        (try! (check-not-paused))
        
        (let ((delegation (unwrap! (map-get? delegations tx-sender) (err ERR-REQUEST-NOT-FOUND))))
            (map-set delegations tx-sender (merge delegation {active: false}))
            (ok true)
        )
    )
)

;; ---------------------------
;; Epoch Management
;; ---------------------------

;; Enhanced epoch checking with performance tracking
(define-public (check-epoch (epoch-rewards-contract <epoch-rewards-trait>))
    (begin
        (try! (check-not-paused))
        
        (let ((current-block stacks-block-height)
              (next-epoch (+ (var-get last-epoch-block) (var-get epoch-length))))
            
            (if (>= current-block next-epoch)
                (begin
                    ;; Update epoch
                    (var-set last-epoch-block current-block)
                    
                    ;; Record performance metrics
                    (map-set performance-metrics current-block {
                        total-staked: (var-get total-staked),
                        apy: (calculate-apy),
                        exchange-rate: (var-get exchange-rate),
                        reward-rate: (if (> (var-get total-staked) u0)
                                      (/ (* (var-get accumulated-rewards) REWARD-PRECISION) (var-get total-staked))
                                      u0),
                        active-stakers: (ft-get-supply stSTX)
                    })
                    
                    ;; Start new epoch in rewards contract
                    (contract-call? epoch-rewards-contract start-new-epoch)
                )
                (ok false)
            )
        )
    )
)

;; Calculate current APY based on rewards
(define-private (calculate-apy)
    (let ((total-value (var-get total-stx-value))
          (total-staked-amount (var-get total-staked)))
        (if (> total-staked-amount u0)
            (/ (* (- total-value total-staked-amount) u10000) total-staked-amount) ;; APY in basis points
            u0
        )
    )
)

;; ---------------------------
;; Administrative Functions
;; ---------------------------

(define-public (set-paused (new-paused bool))
    (begin
        (asserts! (is-contract-owner) (err ERR-UNAUTHORIZED))
        (var-set paused new-paused)
        (ok true)
    )
)

(define-public (set-cooldown-blocks (new-cooldown uint))
    (begin
        (asserts! (is-contract-owner) (err ERR-UNAUTHORIZED))
        (asserts! (and (>= new-cooldown u144) (<= new-cooldown u1440)) (err ERR-INVALID-AMOUNT)) ;; 1-10 days
        (var-set cooldown-blocks new-cooldown)
        (ok true)
    )
)

(define-public (set-min-stake-amount (new-min uint))
    (begin
        (asserts! (is-contract-owner) (err ERR-UNAUTHORIZED))
        (asserts! (>= new-min u100000) (err ERR-INVALID-AMOUNT)) ;; Minimum 0.1 STX
        (var-set min-stake-amount new-min)
        (ok true)
    )
)

(define-public (transfer-ownership (new-owner principal))
    (begin
        (asserts! (is-contract-owner) (err ERR-UNAUTHORIZED))
        (var-set contract-owner new-owner)
        (ok true)
    )
)

;; ---------------------------
;; Read-Only Functions
;; ---------------------------

(define-read-only (get-stake-balance (staker principal))
    (match (map-get? staker-balances staker)
        data (get ststx-balance data)
        u0
    )
)

(define-read-only (get-staker-info (staker principal))
    (map-get? staker-balances staker)
)

(define-read-only (get-total-staked)
    (var-get total-staked)
)

(define-read-only (get-exchange-rate)
    (var-get exchange-rate)
)

(define-read-only (get-total-stx-value)
    (var-get total-stx-value)
)

(define-read-only (get-unstaking-request (request-id uint))
    (map-get? unstaking-requests request-id)
)

(define-read-only (get-user-unstaking-requests (user principal))
    (default-to (list) (map-get? user-unstaking-requests user))
)

(define-read-only (get-pox-cycle-info (cycle-id uint))
    (map-get? pox-cycles cycle-id)
)

(define-read-only (get-current-pox-cycle)
    (var-get current-pox-cycle)
)

(define-read-only (get-delegation-info (staker principal))
    (map-get? delegations staker)
)

(define-read-only (get-performance-metrics (timestamp uint))
    (map-get? performance-metrics timestamp)
)

(define-read-only (get-contract-info)
    {
        total-staked: (var-get total-staked),
        total-stx-value: (var-get total-stx-value),
        exchange-rate: (var-get exchange-rate),
        accumulated-rewards: (var-get accumulated-rewards),
        total-rewards-distributed: (var-get total-rewards-distributed),
        current-pox-cycle: (var-get current-pox-cycle),
        paused: (var-get paused),
        cooldown-blocks: (var-get cooldown-blocks),
        min-stake-amount: (var-get min-stake-amount),
        ststx-supply: (ft-get-supply stSTX)
    }
)

(define-read-only (calculate-ststx-value (ststx-amount uint))
    (ststx-to-stx ststx-amount)
)

(define-read-only (calculate-stx-to-ststx (stx-amount uint))
    (stx-to-ststx stx-amount)
)

(define-read-only (get-current-apy)
    (calculate-apy)
)
