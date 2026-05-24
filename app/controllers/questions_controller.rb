class QuestionsController < ApplicationController
  def show
    question = QuestionDefinition.find_by!(key: params[:key])
    answer = Questions::AnswerRunner.call(question)

    render turbo_stream: turbo_stream.update(
      "dashboard_answer",
      partial: "questions/answer_card",
      locals: { answer: answer }
    )
  end
end