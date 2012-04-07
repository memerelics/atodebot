# -*- coding: UTF-8 -*-
require File.expand_path('../../../config', __FILE__)
Dir::foreach(File.expand_path('../../models/', __FILE__)) { |f|
  next if f == "." || f == ".."
  require  File.expand_path("../../models/#{f}", __FILE__)
}
require 'httpclient'
require 'twitter'

Twitter.configure do |c|
  c.consumer_key =       $secret["CONSUMER_KEY"]
  c.consumer_secret =    $secret["CONSUMER_SECRET"]
  c.oauth_token =        $secret["OAUTH_TOKEN"]
  c.oauth_token_secret = $secret["OAUTH_TOKEN_SECRET"]
end

def update
  b = Bookmark.get_first(0)
  txt = b.make_tweet(user: "T_Hash", short_level: 0)
  status = Twitter.update(txt)
  b.inc(:remind_cnt, 1)
  BotPost.store(status, b)
rescue Twitter::Error::Forbidden => e
  error_log_with_trace($botlogger, e, "Long tweet! length: #{txt.length}. Trying to shorten tweet: #{txt}")
  txt = b.make_tweet(user: "T_Hash", short_level: 1)
  begin
    status = Twitter.update(txt)
    b.inc(:remind_cnt, 1)
    BotPost.store(status, b)
  rescue Twitter::Error::Forbidden => e
    error_log_with_trace($botlogger, e, "Long tweet! length: #{txt.length}. Trying to shorten tweet: #{txt}")
    error_mention(e)
  end
rescue => e
  error_log_with_trace($botlogger, e, "Twitter bot update failed.")
  error_mention(e)
end


# shorten returns short url.
# full result looks something like this. {{{
# => {"status_code"=>200,
#  "status_txt"=>"OK",
#  "data"=>
#   {"long_url"=>
#     "http://m.igrs.jp/blog/2012/03/12/why-rubyists-should-try-elixir/",
#    "url"=>"http://bit.ly/I1R2ev",
#    "hash"=>"I1R2ev",
#    "global_hash"=>"yLG6Hd",
#    "new_hash"=>1}}
# }}}
def shorten(url)
  return nil if url.blank?
  hc = HTTPClient.new
  fullurl = "http://api.bitly.com/v3/shorten?longUrl=#{CGI.escape(url)}&login=#{$secret.bitly.login}&apikey=#{$secret.bitly.apikey}"
  res = Hashie::Mash.new(JSON.parse(hc.get_content(fullurl)))
  res.data.url
rescue => e
  error_log_with_trace($botlogger, e, "bit.ly API failed while shortening url: #{url}.")
  error_mention(e)
end

def error_log_with_trace(logger, e, memo)
  logger.error "[#{Time.now.to_s(:db)}] #{memo}"
  logger.error e.message
  logger.error e.backtrace.join("\n")
end

def error_mention(e)
  Twitter.update "@T_Hash なんか #{e.class} とかでエラった＞＜"
end

def fetch_mentions
  latest = Mention.order_by(:posted_at, :desc).first.try(:posted_at) || Time.parse("2012-04-01")
  mentions = Twitter.mentions.select{|m| m.created_at > latest }
  unless mentions.blank?
    mentions.each do |mention|
      Mention.store(mention)
      $botlogger.info "[#{Time.now.to_s(:db)}] mention (#{mention.id} in reply to #{mention.in_reply_to_status_id}) stored."
    end
  end
end

def react_to_mentions(limit=3)
  mentions = Mention.where(processed: false).limit(limit).to_a
  for mention in mentions do
    post = BotPost.where(status_id: mention.in_reply_to).first
    # 宛先tweetがBotPostに登録されてないとき。直叩き更新、[fix: エラー報告]など
    # 工夫できるところだがとりあえずskip.
    if post.blank?
      mention.update_attributes(processed: true)
      $botlogger.info "[#{Time.now.to_s(:db)}] #{mention.status_id} ... could not find BotPost related to the mention. skip it."
      next
    elsif post.bookmark.present? && post.bookmark.closed == true
      status = Twitter.update("@#{mention.from_user} おじいさんそれにはもうリプライしたでしょ",
                              in_reply_to_status_id: mention.status_id)
    end
    case mention.type
    when :read
      post.bookmark.update_attributes(closed: true)
      mention.update_attributes(processed: true)
      status = Twitter.update("@#{mention.from_user} #{$settings.read_replies.sample(1).first} -- 『#{post.bookmark.trunc_title(20)}』 #{post.bookmark.blink}",
                              in_reply_to_status_id: mention.status_id)
      $botlogger.info "[#{Time.now.to_s(:db)}]  #{mention.status_id} ... read article, closed the bookmark."
    when :dead_link
      mention.update_attributes(processed: true)
      status = Twitter.update("@#{mention.from_user} mjd んじゃなしで",
                              in_reply_to_status_id: mention.status_id)
      $botlogger.info "[#{Time.now.to_s(:db)}] #{mention.status_id} ... closed the bookmark with dead link."
    when :thanks
      status = Twitter.update("@#{mention.from_user} いいってことよ",
                              in_reply_to_status_id: mention.status_id)
      mention.update_attributes(processed: true)
    when :sorry
      status = Twitter.update("@#{mention.from_user} 気にすんな",
                              in_reply_to_status_id: mention.status_id)
      mention.update_attributes(processed: true)
    when :unknown
      mention.update_attributes(processed: true)
      $botlogger.info "[#{Time.now.to_s(:db)}] #{mention.status_id} ... unknown mention type. now just skip it."
    end
    BotPost.store(status) if status.present?
  end
rescue => e
  error_log_with_trace($botlogger, e, "error while reacting to mentions.")
  error_mention(e)
end
