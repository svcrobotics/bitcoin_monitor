Rails.application.routes.draw do
  
  
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
  resources :guides, only: [:index, :show]


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
end
