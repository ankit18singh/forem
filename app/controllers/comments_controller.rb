class CommentsController < ApplicationController
  before_action :set_comment, only: %i[update destroy]
  before_action :set_cache_control_headers, only: [:index]
  before_action :authenticate_user!, only: %i[preview create hide unhide]
  after_action :verify_authorized
  after_action only: %i[moderator_create admin_delete] do
    Audit::Logger.log(:moderator, current_user, params.dup)
  end

  # GET /comments
  # GET /comments.json
  # rubocop:disable Metrics/CyclomaticComplexity
  # rubocop:disable Metrics/PerceivedComplexity
  def index
    skip_authorization
    @on_comments_page = true
    @comment = Comment.new
    @podcast = Podcast.find_by(slug: params[:username])

    @root_comment = Comment.find(params[:id_code].to_i(26)) if params[:id_code].present?

    if @podcast
      @user = @podcast
      @commentable = @user.podcast_episodes.find_by(slug: params[:slug]) if @user.podcast_episodes
    else
      @user = User.find_by(username: params[:username]) ||
        Organization.find_by(slug: params[:username]) ||
        not_found
      @commentable = @root_comment&.commentable ||
        @user.articles.find_by(slug: params[:slug]) || nil
      @article = @commentable

      not_found if @commentable && !@commentable.published
    end

    @commentable_type = @commentable.class.name if @commentable

    set_surrogate_key_header "comments-for-#{@commentable.id}-#{@commentable_type}" if @commentable

    render :deleted_commentable_comment unless @commentable
  end
  # rubocop:enable Metrics/CyclomaticComplexity
  # rubocop:enable Metrics/PerceivedComplexity

  # GET /comments/1
  # GET /comments/1.json
  # GET /comments/1/edit

  def edit
    @comment = Comment.find(params[:id_code].to_i(26))
    authorize @comment
    @parent_comment = @comment.parent
    @commentable = @comment.commentable
  end

  # POST /comments
  # POST /comments.json
  def create
    rate_limit!(:comment_creation)

    @comment = Comment.new(permitted_attributes(Comment))
    @comment.user_id = current_user.id

    authorize @comment

    if @comment.save
      checked_code_of_conduct = params[:checked_code_of_conduct].present? && !current_user.checked_code_of_conduct
      current_user.update(checked_code_of_conduct: true) if checked_code_of_conduct

      NotificationSubscription.create(
        user: current_user, notifiable_id: @comment.id, notifiable_type: "Comment", config: "all_comments",
      )
      Notification.send_new_comment_notifications_without_delay(@comment)
      Mention.create_all(@comment)

      if @comment.invalid?
        @comment.destroy
        render json: { error: "comment already exists" }, status: :unprocessable_entity
        return
      end

      render partial: "comments/comment.json"

    elsif (comment = Comment.where(
      body_markdown: @comment.body_markdown,
      commentable_id: @comment.commentable.id,
      ancestry: @comment.ancestry,
    )[1])

      comment.destroy
      render json: { error: "comment already exists" }, status: :unprocessable_entity
    else
      message = @comment.errors_as_sentence
      render json: { error: message }, status: :unprocessable_entity
    end
  # See https://github.com/thepracticaldev/dev.to/pull/5485#discussion_r366056925
  # for details as to why this is necessary
  rescue Pundit::NotAuthorizedError, RateLimitChecker::LimitReached
    raise
  rescue StandardError => e
    skip_authorization

    message = "There was an error in your markdown: #{e}"
    render json: { error: message }, status: :unprocessable_entity
  end

  def moderator_create
    return if rate_limiter.limit_by_action(:comment_creation)

    response_template = ResponseTemplate.find(params[:response_template][:id])
    authorize response_template, :moderator_create?

    moderator = User.find(SiteConfig.mascot_user_id)
    @comment = Comment.new(permitted_attributes(Comment))
    @comment.user_id = moderator.id
    @comment.body_markdown = response_template.content
    authorize @comment

    if @comment.save
      Notification.send_new_comment_notifications_without_delay(@comment)
      Mention.create_all(@comment)

      render json: { status: "created", path: @comment.path }
    elsif (@comment = Comment.where(body_markdown: @comment.body_markdown,
                                    commentable_id: @comment.commentable.id,
                                    ancestry: @comment.ancestry)[0])
      render json: { status: "comment already exists" }, status: :conflict
    else
      render json: { status: @comment&.errors&.full_messages&.to_sentence }, status: :unprocessable_entity
    end
  rescue StandardError => e
    skip_authorization

    message = "There was an error in your markdown: #{e}"
    render json: { error: "error", status: message }, status: :unprocessable_entity
  end

  # PATCH/PUT /comments/1
  # PATCH/PUT /comments/1.json
  def update
    authorize @comment
    if @comment.update(permitted_attributes(@comment).merge(edited_at: Time.zone.now))
      Mention.create_all(@comment)
      redirect_to URI.parse(@comment.path).path, notice: "Comment was successfully updated."
    else
      @commentable = @comment.commentable
      render :edit
    end
  rescue StandardError => e
    @commentable = @comment.commentable
    flash.now[:error] = "There was an error in your markdown: #{e}"
    render :edit
  end

  # DELETE /comments/1
  # DELETE /comments/1.json
  def destroy
    authorize @comment
    if @comment.is_childless?
      @comment.destroy
    else
      @comment.deleted = true
      @comment.save!
    end
    redirect = @comment.commentable&.path || user_path(current_user)
    # NOTE: Brakeman doesn't like redirecting to a path, because of a "possible
    # unprotected redirect". Using URI.parse().path is the recommended workaround.
    redirect_to URI.parse(redirect).path, notice: "Comment was successfully deleted."
  end

  def delete_confirm
    @comment = Comment.find(params[:id_code].to_i(26))
    authorize @comment
  end

  def preview
    skip_authorization
    begin
      permitted_body_markdown = permitted_attributes(Comment)[:body_markdown]
      fixed_body_markdown = MarkdownFixer.fix_for_preview(permitted_body_markdown)
      parsed_markdown = MarkdownParser.new(fixed_body_markdown, source: Comment.new, user: current_user)
      processed_html = parsed_markdown.finalize
    rescue StandardError => e
      processed_html = "<p>😔 There was an error in your markdown</p><hr><p>#{e}</p>"
    end
    respond_to do |format|
      format.json { render json: { processed_html: processed_html }, status: :ok }
    end
  end

  def settings
    @comment = Comment.find(params[:id_code].to_i(26))
    authorize @comment
    @notification_subscription = NotificationSubscription.find_or_initialize_by(
      user_id: @comment.user_id,
      notifiable_id: @comment.id,
      notifiable_type: "Comment",
      config: "all_comments",
    )
    render :settings
  end

  def hide
    @comment = Comment.find(params[:comment_id])
    authorize @comment
    @comment.hidden_by_commentable_user = true
    @comment&.commentable&.update_column(:any_comments_hidden, true)

    Notification.destroy_by(user_id: current_user.id,
                            notifiable_type: "Comment",
                            notifiable_id: params[:comment_id])

    if @comment.save
      render json: { hidden: "true" }, status: :ok
    else
      render json: { errors: @comment.errors_as_sentence, status: 422 }, status: :unprocessable_entity
    end
  end

  def unhide
    @comment = Comment.find(params[:comment_id])
    authorize @comment
    @comment.hidden_by_commentable_user = false
    if @comment.save
      @commentable = @comment&.commentable
      @commentable&.update_columns(
        any_comments_hidden: @commentable.comments.pluck(:hidden_by_commentable_user).include?(true),
      )
      render json: { hidden: "false" }, status: :ok
    else
      render json: { errors: @comment.errors_as_sentence, status: 422 }, status: :unprocessable_entity
    end
  end

  def admin_delete
    @comment = Comment.find(params[:comment_id])
    authorize @comment
    @comment.deleted = true

    if @comment.save
      redirect_url = @comment.commentable&.path
      if redirect_url
        flash[:success] = "Comment was successfully deleted."
        redirect_to redirect_url
      else
        redirect_to_comment_path
      end
    else
      redirect_to_comment_path
    end
  end

  private

  # Use callbacks to share common setup or constraints between actions.
  def set_comment
    @comment = Comment.find(params[:id])
  end

  def redirect_to_comment_path
    flash[:error] = "Something went wrong; Comment NOT deleted."
    redirect_to "#{@comment.path}/mod"
  end
end
