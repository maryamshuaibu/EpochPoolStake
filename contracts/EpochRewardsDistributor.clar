;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
;; Enhanced EpochRewardsDistributor Contract v2.0
;; Features:
;; - Enhanced reward distribution with PoX integration
;; - Dynamic reward calculation based on stake duration
;; - Performance-based reward multipliers
;; - Comprehensive reward tracking and analytics
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

;; ---------------------------
;; Constants and Error Codes
;; ---------------------------

(define-constant ERR-UNAUTHORIZED u100)
(define-constant ERR-REWARD-TRANSFER-FAILED u101)
(define-constant ERR-INVALID-AMOUNT u102)
(define-constant ERR-INVALID-SHARE u103)
(define-constant ERR-EPOCH-NOT-READY u104)
(define-constant ERR-INSUFFICIENT-REWARDS u105)
(define-constant ERR-INVALID-MULTIPLIER u106)
(define-constant ERR-OVERFLOW u107)

(define-constant REWARD-PRECISION u1000000000) ;; 9 decimal precision
(define-constant MAX-MULTIPLIER u2000000) ;; 2.0x maximum multiplier
(define-constant BASE-MULTIPLIER u1000000) ;; 1.0x base multiplier

;; ---------------------------
;; State Variables
;; ---------------------------

(define-data-var epoch-rewards uint u0)
(define-data-var current-epoch uint u0)
(define-data-var rewards-per-cycle uint u0)
(define-data-var total-distributed uint u0)
(define-data-var reward-pool-balance uint u0)
(define-data-var performance-bonus-rate uint u100000) ;; 10% bonus rate

;; ---------------------------
;; Data Maps
;; ---------------------------

;; Enhanced epoch tracking
(define-map epoch-data
    uint ;; epoch-id
    {
        total-rewards: uint,
        total-staked: uint,
        participants: uint,
        start-block: uint,
        end-block: uint,
        distributed: bool,
        performance-score: uint
    }
)

;; Reward distribution tracking
(define-map reward-distributions
    {epoch: uint, staker: principal}
    {
        base-reward: uint,
        performance-bonus: uint,
        loyalty-bonus: uint,
        total-reward: uint,
        distribution-timestamp: uint
    }
)

;; Performance multipliers based on stake duration
(define-map duration-multipliers
    uint ;; duration-in-blocks
    uint ;; multiplier (in micro-units)
)

;; Loyalty program tracking
(define-map loyalty-tracking
    principal
    {
        consecutive-epochs: uint,
        total-rewards-earned: uint,
        loyalty-tier: uint,
        last-claim-epoch: uint
    }
)

;; ---------------------------
;; Validation Functions
;; ---------------------------

(define-private (validate-caller)
    (begin
        (asserts! (is-eq contract-caller .EpochPoolStake) (err ERR-UNAUTHORIZED))
        (ok true)
    )
)

(define-private (validate-amount (amount uint))
    (begin
        (asserts! (> amount u0) (err ERR-INVALID-AMOUNT))
        (ok amount)
    )
)

(define-private (validate-share (share uint))
    (begin
        (asserts! (<= share REWARD-PRECISION) (err ERR-INVALID-SHARE))
        (ok share)
    )
)

(define-private (check-overflow (a uint) (b uint))
    (let ((sum (+ a b)))
        (asserts! (>= sum a) (err ERR-OVERFLOW))
        (ok sum)
    )
)

;; ---------------------------
;; Reward Pool Management
;; ---------------------------

;; Add rewards to the pool (called by staking contract)
(define-public (add-rewards (amount uint))
    (begin
        (try! (validate-caller))
        (try! (validate-amount amount))
        
        ;; Update epoch rewards safely
        (var-set epoch-rewards (try! (check-overflow (var-get epoch-rewards) amount)))
        (var-set reward-pool-balance (try! (check-overflow (var-get reward-pool-balance) amount)))
        
        (ok true)
    )
)

;; Fund reward pool (admin function)
(define-public (fund-reward-pool (amount uint))
    (begin
        (try! (validate-amount amount))
        
        ;; Transfer STX to contract
        (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
        
        ;; Update pool balance
        (var-set reward-pool-balance (try! (check-overflow (var-get reward-pool-balance) amount)))
        
        (ok true)
    )
)

;; ---------------------------
;; Enhanced Reward Distribution
;; ---------------------------

;; Calculate performance multiplier based on stake duration
(define-private (calculate-duration-multiplier (stake-duration uint))
    (let ((weeks (/ stake-duration u1008))) ;; ~1 week in blocks
        (if (>= weeks u52) 
            u1500000 ;; 1.5x for 1+ year
            (if (>= weeks u26) 
                u1300000 ;; 1.3x for 6+ months
                (if (>= weeks u12) 
                    u1200000 ;; 1.2x for 3+ months
                    (if (>= weeks u4) 
                        u1100000 ;; 1.1x for 1+ month
                        BASE-MULTIPLIER ;; 1.0x base
                    )
                )
            )
        )
    )
)

;; Calculate loyalty bonus based on consecutive epochs
(define-private (calculate-loyalty-bonus (consecutive-epochs uint) (base-reward uint))
    (let ((bonus-rate (if (>= consecutive-epochs u365) 
                        u200000 ;; 20% for 1+ year
                        (if (>= consecutive-epochs u180) 
                            u150000 ;; 15% for 6+ months
                            (if (>= consecutive-epochs u90) 
                                u100000 ;; 10% for 3+ months
                                (if (>= consecutive-epochs u30) 
                                    u50000 ;; 5% for 1+ month
                                    u0 ;; No bonus
                                )
                            )
                        )
                      )))
        (/ (* base-reward bonus-rate) REWARD-PRECISION)
    )
)

;; Enhanced reward distribution with multipliers
(define-public (distribute-rewards
        (staker principal)
        (share uint)
        (stake-duration uint)
        (consecutive-epochs uint)
    )
    (begin
        (try! (validate-caller))
        (try! (validate-share share))
        
        (let ((base-reward (/ (* (var-get epoch-rewards) share) REWARD-PRECISION))
              (duration-multiplier (calculate-duration-multiplier stake-duration))
              (current-epoch-id (var-get current-epoch)))
            
            (asserts! (> base-reward u0) (err ERR-INVALID-AMOUNT))
            
            ;; Calculate enhanced rewards
            (let ((performance-bonus (/ (* base-reward (- duration-multiplier BASE-MULTIPLIER)) REWARD-PRECISION))
                  (loyalty-bonus (calculate-loyalty-bonus consecutive-epochs base-reward)))
                
                (let ((total-reward (+ base-reward (+ performance-bonus loyalty-bonus))))
                    
                    ;; Check sufficient balance
                    (asserts! (>= (var-get reward-pool-balance) total-reward) (err ERR-INSUFFICIENT-REWARDS))
                    
                    ;; Transfer reward to staker
                    (try! (as-contract (stx-transfer? total-reward tx-sender staker)))
                    
                    ;; Update balances
                    (var-set reward-pool-balance (- (var-get reward-pool-balance) total-reward))
                    (var-set total-distributed (+ (var-get total-distributed) total-reward))
                    
                    ;; Record distribution
                    (map-set reward-distributions {epoch: current-epoch-id, staker: staker} {
                        base-reward: base-reward,
                        performance-bonus: performance-bonus,
                        loyalty-bonus: loyalty-bonus,
                        total-reward: total-reward,
                        distribution-timestamp: stacks-block-height
                    })
                    
                    ;; Update loyalty tracking
                    (let ((loyalty-data (default-to {
                        consecutive-epochs: u0,
                        total-rewards-earned: u0,
                        loyalty-tier: u0,
                        last-claim-epoch: u0
                    } (map-get? loyalty-tracking staker))))
                        
                        (map-set loyalty-tracking staker {
                            consecutive-epochs: (+ (get consecutive-epochs loyalty-data) u1),
                            total-rewards-earned: (+ (get total-rewards-earned loyalty-data) total-reward),
                            loyalty-tier: (calculate-loyalty-tier (+ (get consecutive-epochs loyalty-data) u1)),
                            last-claim-epoch: current-epoch-id
                        })
                    )
                    
                    (ok total-reward)
                )
            )
        )
    )
)

;; Calculate loyalty tier based on consecutive epochs
(define-private (calculate-loyalty-tier (consecutive-epochs uint))
    (if (>= consecutive-epochs u365) 
        u4 ;; Diamond tier
        (if (>= consecutive-epochs u180) 
            u3 ;; Gold tier
            (if (>= consecutive-epochs u90) 
                u2 ;; Silver tier
                (if (>= consecutive-epochs u30) 
                    u1 ;; Bronze tier
                    u0 ;; No tier
                )
            )
        )
    )
)

;; ---------------------------
;; Epoch Management
;; ---------------------------

;; Start new epoch with enhanced tracking
(define-public (start-new-epoch)
    (begin
        (try! (validate-caller))
        
        (let ((current-epoch-id (var-get current-epoch))
              (new-epoch-id (+ current-epoch-id u1)))
            
            ;; Finalize current epoch if it exists
            (if (> current-epoch-id u0)
                (map-set epoch-data current-epoch-id {
                    total-rewards: (var-get epoch-rewards),
                    total-staked: u0, ;; Will be updated by staking contract
                    participants: u0, ;; Will be updated by staking contract
                    start-block: (match (map-get? epoch-data current-epoch-id)
                        data (get start-block data)
                        u0),
                    end-block: stacks-block-height,
                    distributed: true,
                    performance-score: (calculate-epoch-performance current-epoch-id)
                })
                true
            )
            
            ;; Initialize new epoch
            (map-set epoch-data new-epoch-id {
                total-rewards: u0,
                total-staked: u0,
                participants: u0,
                start-block: stacks-block-height,
                end-block: u0,
                distributed: false,
                performance-score: u0
            })
            
            ;; Update state
            (var-set current-epoch new-epoch-id)
            (var-set epoch-rewards u0)
            
            (ok new-epoch-id)
        )
    )
)

;; Calculate epoch performance score
(define-private (calculate-epoch-performance (epoch-id uint))
    (let ((epoch-info (map-get? epoch-data epoch-id)))
        (match epoch-info
            data (let ((reward-efficiency (if (> (get total-staked data) u0)
                                            (/ (* (get total-rewards data) u10000) (get total-staked data))
                                            u0)))
                ;; Performance score based on reward efficiency and participation
                (+ reward-efficiency (get participants data))
            )
            u0
        )
    )
)

;; Update epoch statistics (called by staking contract)
(define-public (update-epoch-stats (total-staked uint) (participants uint))
    (begin
        (try! (validate-caller))
        
        (let ((current-epoch-id (var-get current-epoch))
              (current-data (default-to {
                total-rewards: u0,
                total-staked: u0,
                participants: u0,
                start-block: stacks-block-height,
                end-block: u0,
                distributed: false,
                performance-score: u0
              } (map-get? epoch-data current-epoch-id))))
            
            (map-set epoch-data current-epoch-id (merge current-data {
                total-staked: total-staked,
                participants: participants
            }))
            
            (ok true)
        )
    )
)

;; ---------------------------
;; Administrative Functions
;; ---------------------------

;; Set performance bonus rate
(define-public (set-performance-bonus-rate (new-rate uint))
    (begin
        (try! (validate-caller))
        (asserts! (<= new-rate u500000) (err ERR-INVALID-MULTIPLIER)) ;; Max 50% bonus
        (var-set performance-bonus-rate new-rate)
        (ok true)
    )
)

;; Emergency withdraw (admin only)
(define-public (emergency-withdraw (amount uint))
    (begin
        (try! (validate-caller))
        (asserts! (<= amount (var-get reward-pool-balance)) (err ERR-INSUFFICIENT-REWARDS))
        
        (try! (as-contract (stx-transfer? amount tx-sender tx-sender)))
        (var-set reward-pool-balance (- (var-get reward-pool-balance) amount))
        
        (ok true)
    )
)

;; ---------------------------
;; Read-Only Functions
;; ---------------------------

(define-read-only (get-epoch-rewards)
    (var-get epoch-rewards)
)

(define-read-only (get-current-epoch)
    (var-get current-epoch)
)

(define-read-only (get-total-distributed)
    (var-get total-distributed)
)

(define-read-only (get-reward-pool-balance)
    (var-get reward-pool-balance)
)

(define-read-only (get-epoch-data (epoch-id uint))
    (map-get? epoch-data epoch-id)
)

(define-read-only (get-reward-distribution (epoch uint) (staker principal))
    (map-get? reward-distributions {epoch: epoch, staker: staker})
)

(define-read-only (get-loyalty-info (staker principal))
    (map-get? loyalty-tracking staker)
)

(define-read-only (calculate-potential-reward 
    (share uint) 
    (stake-duration uint) 
    (consecutive-epochs uint))
    (let ((base-reward (/ (* (var-get epoch-rewards) share) REWARD-PRECISION))
          (duration-multiplier (calculate-duration-multiplier stake-duration)))
        (if (> base-reward u0)
            (let ((performance-bonus (/ (* base-reward (- duration-multiplier BASE-MULTIPLIER)) REWARD-PRECISION))
                  (loyalty-bonus (calculate-loyalty-bonus consecutive-epochs base-reward)))
                (+ base-reward (+ performance-bonus loyalty-bonus))
            )
            u0
        )
    )
)

(define-read-only (get-contract-info)
    {
        epoch-rewards: (var-get epoch-rewards),
        current-epoch: (var-get current-epoch),
        total-distributed: (var-get total-distributed),
        reward-pool-balance: (var-get reward-pool-balance),
        performance-bonus-rate: (var-get performance-bonus-rate)
    }
)
