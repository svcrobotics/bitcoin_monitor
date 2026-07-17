# frozen_string_literal: true

require "net/http"
require "json"

module Ai
  class CodebaseAnswerer
    MODEL = "gpt-4o-mini"

    def self.call(question:)
      new(question: question).call
    end

    def initialize(question:)
      @question = question.to_s.strip
    end

    def call
      search_query = expanded_query(@question)

      chunks =
        if tansa_global_pipeline_question?
          (forced_tansa_pipeline_chunks + Codebase::Searcher.call(search_query, limit: 8)).uniq
        elsif layer1_pipeline_question?
          (forced_layer1_pipeline_chunks + Codebase::Searcher.call(search_query, limit: 8)).uniq
        else
          Codebase::Searcher.call(search_query, limit: 12)
        end

      context = build_context(chunks)
      response = openai_response(prompt(context))

      {
        answer: response,
        sources: chunks.map { |c| { path: c.path, chunk_index: c.chunk_index } }
      }
    end

    private

    def build_context(chunks)
      chunks.map do |chunk|
        <<~TEXT
          FICHIER: #{chunk.path}
          MORCEAU: #{chunk.chunk_index}

          #{chunk.content}
        TEXT
      end.join("\n\n---\n\n")
    end

    def prompt(context)
      <<~PROMPT
        #{Intelligence::TansaArchitecture.prompt}

        IMPORTANT :
        - La carte d'architecture Tansa aide à comprendre le contexte global.
        - Les extraits de code fournis restent la seule source de vérité pour répondre.
        - Si la carte d'architecture et les extraits semblent diverger, privilégie toujours les extraits de code.

        Tu es Tansa Code Intelligence.

        Tu es l'architecte logiciel interne de Tansa.

        Le code source est la source de vérité.

        Tu ne documentes pas des fichiers.
        Tu expliques comment fonctionne réellement Tansa.

        Principe fondamental :
        - Le code est la donnée.
        - L'IA interprète la donnée.
        - Ne jamais inventer.
        - Ne jamais supposer.
        - Répondre uniquement à partir des extraits fournis.

        Mission :
        Quand un utilisateur pose une question :
        1. Identifier les composants impliqués.
        2. Reconstituer les flux de données.
        3. Expliquer les interactions entre composants.
        4. Expliquer les contrôles et audits.
        5. Expliquer l'utilité métier dans Tansa.

        Règles strictes :
        - Ne jamais résumer uniquement le premier fichier trouvé.
        - Toujours expliquer les relations entre les composants.
        - Toujours privilégier les flux plutôt que les objets.
        - Toujours distinguer :
          - collecte ;
          - transformation ;
          - stockage ;
          - audit ;
          - utilisation finale.
        - Utiliser les noms exacts :
          - classes ;
          - services ;
          - jobs ;
          - modèles ;
          - tables ;
          - clés Redis ;
          - queues Sidekiq.
        - Encadrer tous les noms techniques avec des backticks.
        - Ne jamais présenter une table comme active simplement parce qu'elle existe.
        - Décris uniquement les écritures réellement observées dans les extraits.
        - Attention : dans Tansa, `tx_outputs` ne doit pas être présenté comme la table vivante principale si les extraits montrent `utxo_outputs`.
        - Le chemin Layer1 actuel écrit principalement vers `utxo_outputs`.
        - Si `ClusterInputBuilder` est présent dans les extraits, explique qu'il construit les entrées de cluster à partir des données UTXO/spent disponibles.
        - Utilise Markdown correctement.
        - Évite les gros paragraphes.
        - Réponds en français clair.

        Format obligatoire :

        ### Résumé exécutif

        - Explique en quelques phrases ce que fait le système demandé.

        ### Objectif dans Tansa

        - Explique pourquoi ce système existe dans Tansa.

        ### Flux complet des données

        - Décris étape par étape :
          - d'où viennent les données ;
          - où elles transitent ;
          - comment elles sont transformées ;
          - où elles sont stockées ;
          - comment elles sont enrichies ;
          - comment elles sont contrôlées.

        ### Composants impliqués

        - Liste les composants réellement utilisés :
          - services ;
          - jobs ;
          - modèles ;
          - tables ;
          - clés Redis ;
          - queues Sidekiq.

        ### Audit et contrôle qualité

        - Explique comment Tansa vérifie que les données sont fiables.
        - Explique comment Tansa détecte les retards, erreurs ou incohérences.

        ### Utilisation finale

        - Explique comment ces données sont utilisées par :
          - dashboards ;
          - analyses ;
          - acteurs ;
          - clusters ;
          - intelligence ;
          - IA.

        ### Chaîne technique résumée

        - Si la question concerne un pipeline, donne une chaîne courte du type :
          `Bitcoin Core → BlockIngestService → BlockBufferModel → BlockProcessJob → BlockProcessor → OutputBuffer/SpentOutputBuffer → OutputFlusher/SpentOutputFlusher → UtxoOutput → ClusterInputBuilder → ClusterInput → Actors → Intelligence → Dashboard`

        ### Points de vigilance

        - Liste les éléments pouvant provoquer :
          - retard ;
          - incohérence ;
          - perte de données ;
          - blocage du pipeline.

        ### Limites des extraits

        - Précise ce qui n'est pas visible dans les extraits.
        - Ne comble pas les trous par supposition.

        Adaptation selon la question :
        - Si la question porte sur le pipeline complet de Tansa, explique le système global : sources de vérité, Layer1, clusters, actors, marché, système, intelligence et dashboard.
        - Si la question porte sur un pipeline, décris le parcours complet de la donnée.
        - Si la question porte sur une fonctionnalité, décris le parcours complet de cette fonctionnalité.
        - Si la question porte sur un composant, explique sa place dans l'architecture globale.
        - Ne réponds jamais comme une documentation de fichier.
        - Réponds toujours comme une documentation de système.
        - Ne transforme jamais un service ou un concept en nom de table.
        - Si une table n'apparaît pas explicitement comme modèle ou table dans les extraits, ne l'affirme pas.
        - Exemple : ne dis pas `spent_outputs` comme table si les extraits parlent seulement de `SpentOutputWriter` ou de buffer spent.

        QUESTION:
        #{@question}

        EXTRAITS DE CODE:
        #{context}
      PROMPT
    end

    def expanded_query(question)
      return tansa_global_pipeline_expanded_query(question) if tansa_global_pipeline_question?
      return layer1_pipeline_expanded_query(question) if layer1_pipeline_question?

      question
    end

    def tansa_global_pipeline_question?
      normalized = @question.to_s.downcase

      normalized.match?(/tansa/) &&
        normalized.match?(/pipeline|complet|architecture|fonctionne|flux|parcours/)
    end

    def layer1_pipeline_question?
      normalized = @question.to_s.downcase

      normalized.match?(/layer1|layer 1/) &&
        normalized.match?(/pipeline|complet|architecture|fonctionne|traitement|parcours|flux/)
    end

    def tansa_global_pipeline_expanded_query(question)
      <<~QUERY
        #{question}

        Tansa pipeline complet architecture globale Bitcoin Core Layer1 UTXO clusters actors actor labels actor profiles exchange flows whale flows market data external data intelligence router dashboard system health audit Sidekiq Redis OpenAI
      QUERY
    end

    def layer1_pipeline_expanded_query(question)
      <<~QUERY
        #{question}

        Layer1 pipeline complet Bitcoin Core ZMQ block ingestion block buffer block process job
        BlockBufferModel BlockProcessJob BlockProcessor BlockUtxoBatchBuilder TxProcessor
        Redis outputs buffer spent outputs buffer OutputBuffer SpentOutputBuffer
        OutputFlusher SpentOutputFlusher UtxoOutput SpentOutputWriter OutputWriter
        ClusterInput ClusterInputBuilder Layer1Orchestrator ProcessingRunner DrainJob
        HealthSnapshot AuditBlock Sidekiq queues Redis buffers
      QUERY
    end

    def forced_tansa_pipeline_chunks
      paths = [
        # Layer1
        "app/services/blockchain/ingest/block_ingest_service.rb",
        "app/jobs/blockchain/jobs/block_process_job.rb",
        "app/services/blockchain/processing/block_processor.rb",
        "app/services/blockchain/processing/tx_processor.rb",
        "app/services/blockchain/flushers/output_flusher.rb",
        "app/services/blockchain/flushers/spent_output_flusher.rb",
        "app/services/blockchain/utxo/output_writer.rb",
        "app/services/blockchain/utxo/spent_output_writer.rb",
        "app/services/layer1/health_snapshot.rb",

        # Clusters
        "app/services/clusters/cluster_input_builder.rb",
        "app/services/clusters/processor.rb",
        "app/services/clusters/health_snapshot.rb",

        # Actors
        "app/services/actor_profiles/build_from_cluster.rb",
        "app/services/actor_profiles/score_calculator.rb",
        "app/services/actor_labels/refresh_from_actor_profile.rb",
        "app/services/actor_labels/health_snapshot.rb",

        # Exchange / Whale
        "app/services/actors/detect_exchange_core_flows_for_block.rb",
        "app/services/actors/exchange_core_flow_day_builder.rb",
        "app/services/actors/whale_core_flow_day_builder.rb",

        # Market / external data
        "app/services/market_data/refresh_market_context.rb",
        "app/services/economic_indicators/fetch_fred_series.rb",
        "app/services/btc_price.rb",

        # Intelligence
        "app/services/intelligence/router.rb",
        "app/services/intelligence/context_builder.rb",
        "app/services/intelligence/layer1_assistant.rb",
        "app/services/intelligence/cluster_assistant.rb",
        "app/services/intelligence/actor_profiles_assistant.rb",
        "app/services/intelligence/actor_labels_assistant.rb",
        "app/services/intelligence/system_assistant.rb",

        # System
        "app/services/system/blockchain_pipeline_status.rb",
      ]

      CodeChunk.where(path: paths).order(:path, :chunk_index).to_a
    end

    def forced_layer1_pipeline_chunks
      paths = [
        "app/services/blockchain/ingest/block_ingest_service.rb",
        "app/jobs/blockchain/jobs/block_process_job.rb",
        "app/services/blockchain/processing/block_processor.rb",
        "app/services/blockchain/processing/block_utxo_batch_builder.rb",
        "app/services/blockchain/processing/tx_processor.rb",
        "app/services/blockchain/buffers/output_buffer.rb",
        "app/services/blockchain/buffers/spent_output_buffer.rb",
        "app/services/blockchain/flushers/output_flusher.rb",
        "app/services/blockchain/flushers/spent_output_flusher.rb",
        "app/services/blockchain/utxo/output_writer.rb",
        "app/services/blockchain/utxo/spent_output_writer.rb",
        "app/services/clusters/cluster_input_builder.rb",
        "app/services/blockchain/orchestration/layer1_orchestrator.rb",
        "app/services/blockchain/state/processing_runner.rb",
        "app/services/layer1/health_snapshot.rb"
      ]

      CodeChunk.where(path: paths).order(:path, :chunk_index).to_a
    end

    def openai_response(prompt)
      uri = URI("https://api.openai.com/v1/responses")

      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{ENV.fetch("OPENAI_API_KEY").strip}"
      request["Content-Type"] = "application/json"

      request.body = {
        model: MODEL,
        input: prompt
      }.to_json

      response = Net::HTTP.start(
        uri.hostname,
        uri.port,
        use_ssl: true,
        open_timeout: 10,
        read_timeout: 120
      ) do |http|
        http.request(request)
      end

      body = JSON.parse(response.body)

      raise body.inspect unless response.is_a?(Net::HTTPSuccess)

      body.dig("output", 0, "content", 0, "text").to_s
    end
  end
end