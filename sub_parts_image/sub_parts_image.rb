# -*- coding: utf-8 -*-
miquire :mui, 'sub_parts_helper'

require 'gtk2'
require 'cairo'


# 画像ローダー
class ImageLoadHelper

  # 0.2,0.3両対応の優先度設定
  def self.ui_passive
    if Delayer.const_defined?(:UI_PASSIVE)
      Delayer::UI_PASSIVE
    else
      :ui_passive
    end
  end


  # メッセージに含まれるURLとエンティティを抽出する
  def self.extract_urls_by_message(message)
    entities = [
      { :symbol => :entities, :filter => lambda { |images| images.sort { |_| _[:entity][:indices][0] } } },
      { :symbol => :extended_entities, :filter => nil },
    ]

    targets = entities.inject([]) { |result, entities|
      symbol = entities[:symbol]

      if message[symbol]
        if message[symbol][:urls]
          result += message[symbol][:urls].map { |m| { :url => m[:expanded_url], :entity => m } }
        end

        if message[symbol][:media]
          result += message[symbol][:media].map { |m| { :url => m[:media_url], :entity => m } }
        end
      end

      if entities[:filter]
        entities[:filter].call(result)
      else
        result
      end
    }

    targets.uniq { |_| _[:url] }
  end


  # 画像URLを取得
  def self.get_image_urls(message)
    target = extract_urls_by_message(message)

    result = target.map { |entity|
      base_url = entity[:url]
      image_url = Plugin[:openimg].get_image_url(base_url)

      if image_url
        {:page_url => base_url, :image_url => image_url, :entity => entity[:entity] }
      else
        nil
      end
    }.compact

    result
  end


  # 生データをPixbufに変換する
  def self.raw2pixbuf(raw, parts_height)
    loader = Gdk::PixbufLoader.new
    loader.write(raw)
    loader.close
 
    loader.pixbuf
  rescue => e
    puts e
    puts e.backtrace
    Gdk::WebImageLoader.notfound_pixbuf(parts_height, parts_height).melt
  end


  # 画像をダウンロードする
  def self.load_start(msg)
    urls = get_image_urls(msg[:message])

    if urls.empty?
      return
    end

    Delayer.new(ui_passive) {
      msg[:on_image_information].call(urls)
    }

    urls.each_with_index { |url, i|
      main_icon = nil
      parts_height = UserConfig[:subparts_image_height]

      # 画像のロード
      image = Gdk::WebImageLoader.get_raw_data(url[:image_url]) { |data, exception|
        # 即ロード出来なかった => ロード完了

        main_icon = if !exception && data
          ImageLoadHelper.raw2pixbuf(data, parts_height)
        else
          Gdk::WebImageLoader.notfound_pixbuf(parts_height, parts_height).melt
        end

        if main_icon
          # コールバックを呼び出す
          Delayer.new(ui_passive) {
            msg[:on_image_loaded].call(i, url, main_icon)
          }
        end
      }


      main_icon = case image
        # ロード失敗
        when nil
          Gdk::WebImageLoader.notfound_pixbuf(parts_height, parts_height).melt

        # 即ロード出来なかった -> ロード中を表示して後はコールバックに任せる
        when :wait
          Gdk::WebImageLoader.loading_pixbuf(parts_height, parts_height).melt

        # 即ロード成功
        else
          ImageLoadHelper.raw2pixbuf(image, parts_height)
      end

      # コールバックを呼び出す
      Delayer.new(ui_passive) {
        msg[:on_image_loaded].call(i, url, main_icon)
      }
    }
  end


  # 画像ロードを依頼する
  @@queue = nil

  def self.add(message, proc_image_information, proc_image_loaded)
    if !@@queue
      @@queue = Queue.new

      Thread.start {
        while true
          msg = @@queue.pop
          load_start(msg)
        end
      }
    end

    @@queue.push({:message => message, :on_image_information => proc_image_information, :on_image_loaded => proc_image_loaded})
  end
end


# ここからプラグイン本体
Plugin.create :sub_parts_image do
  UserConfig[:subparts_image_height] ||= 200
  UserConfig[:subparts_image_tp] ||= 100
  UserConfig[:subparts_image_round] ||= 10


  settings "インライン画像表示" do
    adjustment("高さ(px)", :subparts_image_height, 10, 999)
    adjustment("濃さ(%)", :subparts_image_tp, 0, 100)
    adjustment("角を丸くする", :subparts_image_round, 0, 200)
  end


  on_boot do |service|
    # YouTube thumbnail
    Plugin[:openimg].addsupport(/^http:\/\/youtu.be\//, nil) { |url, cancel|
      if url =~ /^http:\/\/youtu.be\/([^\?\/\#]+)/
        "http://img.youtube.com/vi/#{$1}/0.jpg"
      else
        nil
      end
    }

    Plugin[:openimg].addsupport(/^https?:\/\/www\.youtube\.com\/watch\?v=/, nil) { |url, cancel|
      if url =~ /^https?:\/\/www\.youtube\.com\/watch\?v=([^\&]+)/
        "http://img.youtube.com/vi/#{$1}/0.jpg"
      else
        nil
      end
    }

    # Nikoniko Video thumbnail
    Plugin[:openimg].addsupport(/^http:\/\/nico.ms\/sm/, nil) { |url, cancel|
      if url =~ /^http:\/\/nico.ms\/sm([0-9]+)/
        "http://tn-skr#{($1.to_i % 4) + 1}.smilevideo.jp/smile?i=#{$1}"
      else
        nil
      end
    }

    Plugin[:openimg].addsupport(/nicovideo\.jp\/watch\//, nil) { |url, cancel|
      if url =~ /nicovideo\.jp\/watch\/sm([0-9]+)/
        "http://tn-skr#{($1.to_i % 4) + 1}.smilevideo.jp/smile?i=#{$1}"
      else
        nil
      end
    }
  end


  # サブパーツ
  class Gdk::SubPartsImage < Gdk::SubParts
    regist

    def on_image_loaded(pos, url, pixbuf)
      # イメージ取得完了

      if !helper.destroyed?
        # 再描画イベント
        sid = helper.ssc(:expose_event, helper) {
          # サブパーツ描画
          helper.on_modify
          helper.signal_handler_disconnect(sid)
          false 
        }
      end

      # 初回表示の場合、TLの高さを変更する
      first_disp = @main_icons.empty?
      @main_icons[pos] = pixbuf

      if first_disp
        helper.reset_height
      end

      # サブパーツ描画
      helper.on_modify
    end


    def on_image_information(urls)
      @num = urls.length

      if !helper.destroyed?
        # クリックイベント
        @ignore_event = false

        if @click_sid
           helper.signal_handler_disconnect(@click_sid)
           @click_sid = nil
        end

        @click_sid = helper.ssc(:click) { |this, e, x, y|
          # クリック位置の特定
          offset = helper.mainpart_height

          helper.subparts.each { |part|
            if part == self
              break
            end

            offset += part.height
          }

          # どの icon が押されたかを判定
          @main_icons.each_with_index { |icon, i|
            if icon then
              left = icon.instance_variable_get(:@scaled_offset_x)
              top = icon.instance_variable_get(:@scaled_offset_y)
              right = left + icon.instance_variable_get(:@scaled_width)
              bottom = top + icon.instance_variable_get(:@scaled_height)

              offseted_y = y - offset

              # イメージをクリックしたか
              if (x >= left && x <= right &&
                  offseted_y >= top && offseted_y <= bottom) then
                case e.button
                when 1
                  Gtk::openurl(urls[i][:page_url])

                  @ignore_event = true

                  Thread.new {
                    sleep(0.5)
                    @ignore_event = false
                  }
                end

                # クリックしたイメージにたどり着いたら終了
                break
              end
            end
          }
        }
      end
    end


    def initialize(*args)
      super
      @main_icons = []
      @prev_width = -1

      if message
        # イメージ読み込みスレッドを起こす
        ImageLoadHelper.add(message, method(:on_image_information), method(:on_image_loaded))
      end
    end


    # サブパーツを描画
    def render(context)
      parts_height = UserConfig[:subparts_image_height].to_f
      get_scaled_sizes()

      offset_row = 0
      offset_x = 0.0
      Array(@main_icons).each_with_index { |icon, i|
        if icon

          context.save {
            width = icon.instance_variable_get(:@scaled_width)

            # はみ出しチェック
            if offset_x + width.to_i > helper.width then
              offset_x = 0.0
              offset_row += 1
            end

            # アイコンの描画座標情報を記録
            scale = icon.instance_variable_get(:@scale_xy)
            icon.instance_variable_set(:@scaled_offset_x, offset_x)
            icon.instance_variable_set(:@scaled_offset_y, icon.height.to_f * offset_row.to_f * scale)

            context.translate(offset_x, parts_height * offset_row.to_f)
            context.scale(scale, scale)
            context.set_source_pixbuf(icon)

            context.clip {
              round = UserConfig[:subparts_image_round] / scale
              context.rounded_rectangle(0, 0, icon.width, icon.height, round)
            }

            context.paint(UserConfig[:subparts_image_tp] / 100.0)

            offset_x += width
          }
        end
      }
    end


    def height
      if !@main_icons.empty?
        calc_subparts_height
      else
        0
      end
    end


    private

    def message
      helper.message
    end

    def calc_subparts_height
      get_scaled_sizes()

      offset_row = 0
      offset_x = 0.0
      Array(@main_icons).each_with_index { |icon, i|
        if icon
          width = icon.instance_variable_get(:@scaled_width)

          # はみ出しチェック
          if offset_x + width.to_i > helper.width then
            offset_x = 0.0
            offset_row += 1
          end

          offset_x += width
        end
      }

      row = offset_row + 1
      row * UserConfig[:subparts_image_height]
    end

    def get_scaled_sizes
      parts_height = UserConfig[:subparts_image_height].to_f
      Array(@main_icons).each_with_index { |icon, i|
          if icon then
            width_ratio = helper.width.to_f / icon.width.to_f
            height_ratio = parts_height.to_f / icon.height.to_f
            scale_xy = [height_ratio, width_ratio].min

            width = icon.width.to_f * scale_xy
            height = icon.height.to_f * scale_xy

            icon.instance_variable_set(:@scale_xy, scale_xy)
            icon.instance_variable_set(:@scaled_width, width)
            icon.instance_variable_set(:@scaled_height, height)
          end
      }
      @prev_width = helper.width
    end
  end
end
