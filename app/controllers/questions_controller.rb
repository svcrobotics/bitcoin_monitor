class QuestionsController < ApplicationController
  def show
    question = QuestionDefinition.find_by!(key: params[:key])

    if layer1_question?(question)
      snapshot = Layer1::OverviewSnapshot.call

      render turbo_stream: turbo_stream.update(
        "dashboard_answer",
        partial: "questions/answers/layer1",
        locals: { snapshot: snapshot }
      )

      return
    end

    answer = Questions::AnswerRunner.call(question)

    render turbo_stream: turbo_stream.update(
      "dashboard_answer",
      partial: "questions/answer_card",
      locals: { answer: answer }
    )
  end

  def live
    case params[:kind]
    when "layer1"
      snapshot =
        Layer1::OverviewSnapshot.call

      render partial: "questions/answers/layer1_frame",
             locals: {
               snapshot: snapshot
             }

    when "cluster"
      snapshot = Intelligence::ContextBuilder.cluster_health
      render partial: "questions/answers/cluster_frame",
             locals: {
               snapshot: snapshot[:raw_snapshot] || snapshot
             }

    when "actor_profiles"
      snapshot =
        ActorProfiles::OperationalSnapshot.read

      render partial: "questions/answers/actor_profiles_frame",
             locals: {
               snapshot: snapshot
             }

    else
      head :not_found
    end
  end

  private

  def layer1_question?(question)
    text = [
      question.key,
      question.question,
      question.intent,
      question.module_name
    ].compact.join(" ").downcase

    text.match?(/layer\s*1|layer1|lag|blockchain|utxo|outputs/)
  end
end