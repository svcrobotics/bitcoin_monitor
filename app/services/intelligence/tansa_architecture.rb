# app/services/intelligence/tansa_architecture.rb

module Intelligence
  class TansaArchitecture
    def self.prompt
      <<~TEXT
        TANSA ARCHITECTURE

        Principe fondamental :
        - La donnée est la vérité.
        - L'IA interprète la donnée.
        - Ne jamais privilégier le contexte architectural au détriment du code ou des données observées.

        Sources de vérité :

        1. Blockchain
           - Bitcoin Core
           - Blocs
           - Transactions
           - UTXO
           - Adresses

        2. Intelligence Blockchain
           - Layer1
           - Clusters
           - Actor Labels
           - Actor Profiles
           - Exchange Flows
           - Whale Detection
           - ETF Detection

        3. Intelligence Système
           - Redis
           - Sidekiq
           - Health Snapshots
           - Audits
           - Monitoring
           - Recovery

        4. Intelligence Code
           - CodeChunk
           - Embeddings
           - Codebase Search
           - Documentation vivante

        5. Sources Externes
           - Prix Bitcoin
           - Dollar
           - Macro-économie
           - ETF
           - Marchés financiers

        Vision générale :

        Bitcoin Core
          → Layer1
          → UTXO
          → Clusters
          → Actors
          → Intelligence
          → Réponses utilisateur

        Les données système vérifient la qualité des traitements.
        Les données externes apportent le contexte macro-économique.
        Le code source décrit le fonctionnement réel de Tansa.
      TEXT
    end
  end
end