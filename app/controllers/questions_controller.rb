class QuestionsController < ApplicationController
  def show
    question = QuestionDefinition.find_by!(key: params[:key])

    if layer1_question?(question)
      snapshot = Layer1::CachedHealthSnapshot.read

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