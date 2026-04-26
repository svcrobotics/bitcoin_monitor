Rails.application.routes.draw do
  get "pages/about"
  get "/address-search", to: "address_lookup#search", as: :address_search
  get "/address/:address", to: "address_lookup#show", as: :address_lookup
  
  resources :trade_simulations do
    member do
      get  :close
      patch :close, action: :close_update
    end
  end

  resources :journal_entries
  
  namespace :btc do
    resource :dashboard, only: [:show], controller: :dashboard
  end

  get "system/recovery", to: "system#recovery"

  root "dashboard#index"

  # Route nommée pour le dashboard
  get "/dashboard", to: "dashboard#index", as: :dashboard
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  # root "posts#index"
  resources :blocks, only: [:index, :show]
  resources :transactions, only: [:show]
  resources :guides, param: :slug

  # Page dédiée BRC-20
  get "brc20", to: "brc20#index", as: :brc20

  # Page "profil" d'un token BRC-20
  get "brc20/:tick", to: "brc20_tokens#show", as: :brc20_token

  get "runes", to: "runes#index", as: :runes

  resources :feature_requests do
    member do
      post :generate_invoice
    end
  end

  post "/btcpay/webhook", to: "btcpay_webhooks#receive"

  get  "/vaults/login",  to: "vaults_auth#new"
  post "/vaults/challenge", to: "vaults_auth#challenge"
  post "/vaults/verify", to: "vaults_auth#verify"
  delete "/vaults/logout", to: "vaults_auth#destroy"
  
  resources :vaults do
    member do
      post :import_watch_only
      post :derive_addresses
    end

    resources :vault_addresses, only: [:index]

    collection do
      get :docs
    end
  end

  resources :whale_alerts, only: [:index]
  post "/market_context/refresh", to: "market_contexts#refresh", as: :market_context_refresh
  post "/price_zones/refresh", to: "price_zones#refresh", as: :price_zones_refresh
  post "/ui_mode", to: "ui_mode#update", as: :ui_mode
  
  post "/ai/dashboard_insight", to: "ai#dashboard_insight", as: :ai_dashboard_insight

  get "/market/price", to: "market#price", as: :market_price

  get "/system", to: "system#index"

  resources :opsec_assessments, only: %i[new create show]
  get "/opsec", to: "opsec_assessments#new"

  get "/about", to: "pages#about"
  
  get "/terms", to: "pages#terms", as: :terms
  get "/privacy", to: "pages#privacy", as: :privacy
  get "/risk-disclosure", to: "pages#risk", as: :risk_disclosure
  get "/contact", to: "pages#contact", as: :contact

  get "exchange_like", to: "exchange_like#index"
  get "inflow_outflow", to: "inflow_outflow#index"

  resources :clusters, only: [:index, :show]
  get "/cluster_signals", to: "cluster_signals#index"
  get "/cluster_signals/top", to: "cluster_signals#top", as: :top_cluster_signals

  get "/system/tests", to: "system#tests", as: :system_tests
  post "/system/tests/run", to: "system#run_tests", as: :run_system_tests


end
