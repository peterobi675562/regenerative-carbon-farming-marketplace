;; Regenerative Farming Incentivizer
;; Manages farmer onboarding and practice verification, automates carbon credit issuance,
;; and facilitates direct sales to corporate buyers with transparent pricing.

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant ERR_UNAUTHORIZED (err u1))
(define-constant ERR_INVALID_CREDIT (err u2))
(define-constant ERR_INSUFFICIENT_CREDITS (err u3))
(define-constant ERR_INVALID_BUYER (err u4))
(define-constant ERR_PRICE_TOO_LOW (err u5))
(define-constant ERR_INVALID_PRACTICE (err u6))

;; Credit status constants
(define-constant CREDIT_PENDING u1)
(define-constant CREDIT_VERIFIED u2)
(define-constant CREDIT_SOLD u3)
(define-constant CREDIT_RETIRED u4)

;; Carbon credits registry
(define-map carbon-credits
  { credit-id: (buff 32) }
  {
    farm-id: (buff 32),
    farmer: principal,
    amount: uint, ;; tonnes CO2e * 100
    vintage: uint, ;; year
    issuance-date: uint,
    verification-date: uint,
    status: uint,
    price: uint, ;; per tonne * 100
    co-benefits: (list 5 (string-ascii 16)),
    methodology: (string-ascii 32)
  }
)

;; Corporate buyer registry
(define-map corporate-buyers
  { buyer: principal }
  {
    company-name: (string-ascii 64),
    registration-date: uint,
    total-purchases: uint,
    sustainability-goals: (list 5 (string-ascii 32)),
    is-verified: bool,
    credit-limit: uint
  }
)

;; Carbon credit transactions
(define-map credit-transactions
  { transaction-id: (buff 32) }
  {
    credit-id: (buff 32),
    seller: principal,
    buyer: principal,
    amount: uint,
    price-per-tonne: uint,
    total-price: uint,
    transaction-date: uint,
    co-benefits-premium: uint
  }
)

;; Farming practice verification
(define-map practice-verifications
  { verification-id: (buff 32) }
  {
    farm-id: (buff 32),
    practice: (string-ascii 16),
    verification-date: uint,
    verifier: principal,
    compliance-score: uint,
    impact-estimate: uint, ;; CO2e tonnes * 100
    evidence-hash: (buff 32)
  }
)

;; Incentive payments to farmers
(define-map incentive-payments
  { payment-id: (buff 32) }
  {
    recipient: principal,
    farm-id: (buff 32),
    amount: uint,
    payment-type: (string-ascii 16), ;; "practice", "credit-sale", "bonus"
    payment-date: uint,
    practice: (optional (string-ascii 16))
  }
)

;; Global marketplace statistics
(define-data-var total-credits-issued uint u0)
(define-data-var total-credits-sold uint u0)
(define-data-var total-revenue uint u0)
(define-data-var average-credit-price uint u2500) ;; $25.00 per tonne
(define-data-var platform-fee-rate uint u300) ;; 3%

;; Private helper functions

;; Generate unique credit ID
(define-private (generate-credit-id (farm-id (buff 32)) (timestamp uint))
  (sha256 (concat farm-id (unwrap-panic (to-consensus-buff? timestamp))))
)

;; Calculate co-benefits premium
(define-private (calculate-cobenefits-premium (base-price uint) (cobenefits (list 5 (string-ascii 16))))
  (let (
    (premium-rate (* (len cobenefits) u200)) ;; 2% per co-benefit
  )
    (/ (* base-price premium-rate) u10000)
  )
)

;; Validate farming practice
(define-private (is-valid-practice (practice (string-ascii 16)))
  (or
    (is-eq practice "cover-cropping")
    (or
      (is-eq practice "no-till")
      (or
        (is-eq practice "rotational-grazing")
        (or
          (is-eq practice "agroforestry")
          (or
            (is-eq practice "composting")
            (is-eq practice "precision-ag")
          )
        )
      )
    )
  )
)

;; Calculate platform fee
(define-private (calculate-platform-fee (transaction-amount uint))
  (/ (* transaction-amount (var-get platform-fee-rate)) u10000)
)

;; Public functions for credit management

;; Issue carbon credits based on verified measurements
(define-public (issue-carbon-credits
  (farm-id (buff 32))
  (farmer principal)
  (amount uint)
  (vintage uint)
  (co-benefits (list 5 (string-ascii 16)))
  (methodology (string-ascii 32))
)
  (let (
    (credit-id (generate-credit-id farm-id stacks-block-height))
    (current-block stacks-block-height)
    (base-price (var-get average-credit-price))
    (premium (calculate-cobenefits-premium base-price co-benefits))
  )
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (> amount u0) ERR_INVALID_CREDIT)
    
    ;; Issue credits
    (map-set carbon-credits
      { credit-id: credit-id }
      {
        farm-id: farm-id,
        farmer: farmer,
        amount: amount,
        vintage: vintage,
        issuance-date: current-block,
        verification-date: current-block,
        status: CREDIT_VERIFIED,
        price: (+ base-price premium),
        co-benefits: co-benefits,
        methodology: methodology
      }
    )
    
    ;; Update global counter
    (var-set total-credits-issued (+ (var-get total-credits-issued) amount))
    
    (ok credit-id)
  )
)

;; Register corporate buyer
(define-public (register-corporate-buyer
  (company-name (string-ascii 64))
  (sustainability-goals (list 5 (string-ascii 32)))
  (credit-limit uint)
)
  (let (
    (current-block stacks-block-height)
  )
    (asserts! (> credit-limit u0) ERR_INVALID_BUYER)
    (asserts! (is-none (map-get? corporate-buyers { buyer: tx-sender })) ERR_INVALID_BUYER)
    
    ;; Register buyer
    (map-set corporate-buyers
      { buyer: tx-sender }
      {
        company-name: company-name,
        registration-date: current-block,
        total-purchases: u0,
        sustainability-goals: sustainability-goals,
        is-verified: false, ;; Requires manual verification
        credit-limit: credit-limit
      }
    )
    
    (ok true)
  )
)

;; Purchase carbon credits
(define-public (purchase-credits
  (credit-id (buff 32))
  (amount uint)
  (max-price-per-tonne uint)
)
  (let (
    (credit-data (unwrap! (map-get? carbon-credits { credit-id: credit-id }) ERR_INVALID_CREDIT))
    (buyer-data (unwrap! (map-get? corporate-buyers { buyer: tx-sender }) ERR_INVALID_BUYER))
    (transaction-id (sha256 (concat credit-id (unwrap-panic (to-consensus-buff? tx-sender)))))
    (current-block stacks-block-height)
  )
    (asserts! (get is-verified buyer-data) ERR_UNAUTHORIZED)
    (asserts! (is-eq (get status credit-data) CREDIT_VERIFIED) ERR_INVALID_CREDIT)
    (asserts! (<= amount (get amount credit-data)) ERR_INSUFFICIENT_CREDITS)
    (asserts! (<= (get price credit-data) max-price-per-tonne) ERR_PRICE_TOO_LOW)
    
    (let (
      (price-per-tonne (get price credit-data))
      (total-price (* amount price-per-tonne))
      (platform-fee (calculate-platform-fee total-price))
      (farmer-payment (- total-price platform-fee))
      (cobenefits-premium (calculate-cobenefits-premium price-per-tonne (get co-benefits credit-data)))
    )
      ;; Record transaction
      (map-set credit-transactions
        { transaction-id: transaction-id }
        {
          credit-id: credit-id,
          seller: (get farmer credit-data),
          buyer: tx-sender,
          amount: amount,
          price-per-tonne: price-per-tonne,
          total-price: total-price,
          transaction-date: current-block,
          co-benefits-premium: cobenefits-premium
        }
      )
      
      ;; Update credit status
      (map-set carbon-credits
        { credit-id: credit-id }
        (merge credit-data {
          status: CREDIT_SOLD,
          amount: (- (get amount credit-data) amount)
        })
      )
      
      ;; Update buyer statistics
      (map-set corporate-buyers
        { buyer: tx-sender }
        (merge buyer-data {
          total-purchases: (+ (get total-purchases buyer-data) amount)
        })
      )
      
      ;; Update global statistics
      (var-set total-credits-sold (+ (var-get total-credits-sold) amount))
      (var-set total-revenue (+ (var-get total-revenue) total-price))
      
      (ok transaction-id)
    )
  )
)

;; Verify farming practice implementation
(define-public (verify-farming-practice
  (farm-id (buff 32))
  (practice (string-ascii 16))
  (compliance-score uint)
  (impact-estimate uint)
  (evidence-hash (buff 32))
)
  (let (
    (verification-id (sha256 (concat farm-id (unwrap-panic (to-consensus-buff? practice)))))
    (current-block stacks-block-height)
  )
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (is-valid-practice practice) ERR_INVALID_PRACTICE)
    (asserts! (<= compliance-score u100) ERR_INVALID_PRACTICE)
    
    ;; Record practice verification
    (map-set practice-verifications
      { verification-id: verification-id }
      {
        farm-id: farm-id,
        practice: practice,
        verification-date: current-block,
        verifier: tx-sender,
        compliance-score: compliance-score,
        impact-estimate: impact-estimate,
        evidence-hash: evidence-hash
      }
    )
    
    (ok verification-id)
  )
)

;; Issue incentive payment to farmer
(define-public (issue-incentive-payment
  (recipient principal)
  (farm-id (buff 32))
  (amount uint)
  (payment-type (string-ascii 16))
  (practice (optional (string-ascii 16)))
)
  (let (
    (payment-id (sha256 (concat (unwrap-panic (to-consensus-buff? recipient)) (unwrap-panic (to-consensus-buff? amount)))))
    (current-block stacks-block-height)
  )
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (> amount u0) ERR_INVALID_CREDIT)
    
    ;; Record payment
    (map-set incentive-payments
      { payment-id: payment-id }
      {
        recipient: recipient,
        farm-id: farm-id,
        amount: amount,
        payment-type: payment-type,
        payment-date: current-block,
        practice: practice
      }
    )
    
    (ok payment-id)
  )
)

;; Update average credit price based on market activity
(define-public (update-credit-price (new-average-price uint))
  (begin
    (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_UNAUTHORIZED)
    (asserts! (> new-average-price u0) ERR_PRICE_TOO_LOW)
    
    (var-set average-credit-price new-average-price)
    (ok new-average-price)
  )
)

;; Read-only functions

;; Get carbon credit information
(define-read-only (get-credit-info (credit-id (buff 32)))
  (map-get? carbon-credits { credit-id: credit-id })
)

;; Get corporate buyer information
(define-read-only (get-buyer-info (buyer principal))
  (map-get? corporate-buyers { buyer: buyer })
)

;; Get transaction details
(define-read-only (get-transaction (transaction-id (buff 32)))
  (map-get? credit-transactions { transaction-id: transaction-id })
)

;; Get practice verification
(define-read-only (get-practice-verification (verification-id (buff 32)))
  (map-get? practice-verifications { verification-id: verification-id })
)

;; Get marketplace statistics
(define-read-only (get-marketplace-stats)
  (ok {
    total-credits-issued: (var-get total-credits-issued),
    total-credits-sold: (var-get total-credits-sold),
    total-revenue: (var-get total-revenue),
    average-price: (var-get average-credit-price),
    platform-fee-rate: (var-get platform-fee-rate)
  })
)

