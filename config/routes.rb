Rails.application.routes.draw do
  get "tansa/heartbeat", to: "tansa_heartbeat#show", as: :tansa_heartbeat
  get "questions/live/actor-labels-strict", to: "questions/actor_labels_live#show"
  get "questions/live/:module_name", to: "questions/live_answers#show", as: :questions_live_answer
  
  get "search/index"

  namespace :clusters do
    resources :events, only: [:index]
  end
  
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

  # get "/market/price", to: "market#price", as: :market_price


  resources :opsec_assessments, only: %i[new create show]
  get "/opsec", to: "opsec_assessments#new"

  get "/about", to: "pages#about"
  
  get "/terms", to: "pages#terms", as: :terms
  get "/privacy", to: "pages#privacy", as: :privacy
  get "/risk-disclosure", to: "pages#risk", as: :risk_disclosure
  get "/contact", to: "pages#contact", as: :contact

  get "exchange_like", to: "exchange_like#index"
  #get "inflow_outflow", to: "inflow_outflow#index"

  resources :clusters, only: [:index, :show]

  get "search", to: "search#index", as: :search
  get "search/live", to: "search#live", as: :live_search

  resources :actor_labels, only: [:index]

  namespace :actors do
    get "exchange_core_flows", to: "exchange_core_flows#index"
  end

  get "dashboard/exchange_core_netflow",
    to: "dashboard#exchange_core_netflow",
    as: :dashboard_exchange_core_netflow

  namespace :actors do
    get "exchange_core_flows/live",
      to: "exchange_core_flows#live",
      as: :exchange_core_flows_live
  end

  get "/questions/:key", to: "questions#show", as: :question


  namespace :actors do
    resources :whale_core_flows, only: [:index]
  end

  post "ai/dashboard_answer", to: "ai/dashboard_answers#create", as: :ai_dashboard_answer


  get "layer1/health", to: "layer1_health#show", as: :layer1_health


  get "system/layer1_audit", to: "layer1_audit#show", as: :system_layer1_audit
  post "system/layer1_audit/run", to: "layer1_audit#run", as: :system_layer1_audit_run

  get "questions/live/:kind", to: "questions#live", as: :live_question
end
