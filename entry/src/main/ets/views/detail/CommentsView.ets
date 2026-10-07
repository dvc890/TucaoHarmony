/**
 * 视频「评论」Tab 视图
 * 由 VideoDetail 评论 Tab 挂载（接线）：
 *   CommentsView({ typeid: video.typeid, hid: video.hid })
 * - 发射框（未登录跳登录）→ 乐观「发射中」插入，失败回滚
 * - 评论项：头像/昵称/等级/楼层/相对时间/富文本内容(RichTextView)/顶(乐观+1)/回复数
 * - 分页：上一页 / 下一页（每页 20 条）
 */
import { CommentsVM } from '../../viewmodel/CommentsVM';
import { Comment } from '../../model/entity/CommentEntities';
import { Router } from '../../common/Router';
import { NetworkImage } from '../../components/NetworkImage';
import { EmptyView } from '../../components/EmptyView';
import { ErrorRetry } from '../../components/ErrorRetry';
import { LoadingState } from '../../components/LoadingState';
import { RelativeTime } from '../../components/RelativeTimeText';
import { RichTextView } from '../../components/RichTextView';

@ComponentV2
export struct CommentsView {
  /** 视频 typeid（commentid 组装） */
  @Param typeid: number = 0;
  /** 视频 hid */
  @Param hid: string = '';
  @Local vm: CommentsVM = new CommentsVM();

  aboutToAppear(): void {
    this.vm.init(this.typeid, this.hid);
  }

  /** 同一 VideoDetail 实例复用时切换视频 → 重新加载评论 */
  @Monitor('typeid', 'hid')
  onVideoChanged(monitor: IMonitor): void {
    this.vm.init(this.typeid, this.hid);
  }

  /** 发射评论 */
  private async doSend(): Promise<void> {
    const result: string = await this.vm.send();
    if (result === 'needLogin') {
      this.getUIContext().getPromptAction().showToast({ message: '请先登录' });
    } else if (result.length > 0) {
      this.getUIContext().getPromptAction().showToast({ message: result });
    }
  }

  /** 点赞（乐观 +1，失败回滚提示） */
  private async doSupport(comment: Comment): Promise<void> {
    if (comment.support) {
      return;
    }
    await this.vm.toggleSupport(comment);
    if (!comment.support) {
      this.getUIContext().getPromptAction().showToast({ message: '点赞失败，请重试' });
    }
  }

  /** 单条评论 */
  @Builder
  commentItem(comment: Comment) {
    Column() {
      Row({ space: $r('app.float.space_md') }) {
        NetworkImage({
          url: comment.avatar,
          imageWidth: 36,
          imageHeight: 36,
          radius: 18
        })
        Column({ space: $r('app.float.space_xs') }) {
          Row({ space: $r('app.float.space_sm') }) {
            Text(comment.nickname)
              .fontSize($r('app.float.font_size_body'))
              .fontColor($r('app.color.text_primary'))
              .maxLines(1)
              .layoutWeight(1)
            Text(comment.level)
              .fontSize($r('app.float.font_size_caption'))
              .fontColor($r('app.color.brand'))
          }
          .width('100%')
          if (comment.lch.length > 0 || !comment.hasSend) {
            Row({ space: $r('app.float.space_sm') }) {
              if (comment.lch.length > 0) {
                Text(comment.lch)
                  .fontSize($r('app.float.font_size_caption'))
                  .fontColor($r('app.color.text_tertiary'))
              }
              if (!comment.hasSend) {
                Text('发射中')
                  .fontSize($r('app.float.font_size_caption'))
                  .fontColor($r('app.color.text_tertiary'))
              } else {
                Text(RelativeTime.format(comment.time))
                  .fontSize($r('app.float.font_size_caption'))
                  .fontColor($r('app.color.text_tertiary'))
              }
            }
            .width('100%')
          }
          // 评论内容（富文本，失败回退纯文本）
          RichTextView({
            html: comment.infoHtml,
            fallbackText: comment.info,
            baseFontSize: 15,
            contentWidthVp: this.vm.contentWidthVp
          })
          Row({ space: $r('app.float.space_lg') }) {
            // 顶（乐观 +1）
            Text(comment.support ? `已顶 ${comment.thumbUp}` : `顶 ${comment.thumbUp}`)
              .fontSize($r('app.float.font_size_caption'))
              .fontColor(comment.support ? $r('app.color.brand') : $r('app.color.text_secondary'))
              .onClick((): void => {
                this.doSupport(comment);
              })
            // 回复数 → 楼中楼
            if (comment.hasSend && comment.replyNum > 0) {
              Text(`回复 ${comment.replyNum}`)
                .fontSize($r('app.float.font_size_caption'))
                .fontColor($r('app.color.text_secondary'))
            }
          }
          .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)
      .onClick((): void => {
        if (comment.hasSend && comment.id.length > 0) {
          this.vm.openReplyFloor(comment);
        }
      })
    }
    .width('100%')
    .padding({
      top: $r('app.float.space_md'),
      bottom: $r('app.float.space_md')
    })
  }

  build() {
    Column() {
      List({ space: 0 }) {
        // 发射框
        ListItem() {
          Row({ space: $r('app.float.space_md') }) {
            TextInput({ text: this.vm.draft, placeholder: '吐槽一下…' })
              .fontSize($r('app.float.font_size_body'))
              .height(40)
              .layoutWeight(1)
              .backgroundColor($r('app.color.card_background'))
              .borderRadius($r('app.float.radius_card'))
              .onChange((value: string): void => {
                this.vm.draft = value;
              })
            Button(this.vm.sending ? '发射中' : '发射')
              .fontSize($r('app.float.font_size_body'))
              .fontColor($r('app.color.text_on_brand'))
              .backgroundColor($r('app.color.brand'))
              .borderRadius($r('app.float.radius_button'))
              .height(40)
              .padding({ left: $r('app.float.space_md'), right: $r('app.float.space_md') })
              .enabled(!this.vm.sending)
              .onClick((): void => {
                this.doSend();
              })
          }
          .width('100%')
          .padding({
            left: $r('app.float.space_md'),
            right: $r('app.float.space_md'),
            top: $r('app.float.space_sm')
          })
        }

        if (this.vm.loading && this.vm.comments.length === 0) {
          // 首次加载
          ListItem() {
            LoadingState({ message: '评论加载中…' })
          }
        } else if (this.vm.error.length > 0 && this.vm.comments.length === 0) {
          // 加载失败（空列表时）
          ListItem() {
            ErrorRetry({
              message: this.vm.error,
              onRetry: (): void => {
                this.vm.loadPage(1);
              }
            })
          }
        } else if (this.vm.comments.length === 0) {
          // 空评论
          ListItem() {
            EmptyView({ message: '还没有评论，快来抢沙发' })
          }
        } else {
          // 评论列表
          ForEach(this.vm.comments, (comment: Comment) => {
            ListItem() {
              this.commentItem(comment)
            }
          }, (comment: Comment, index: number): string => `${index}-${comment.id}-${comment.time}`)
        }

        // 分页条
        if (this.vm.comments.length > 0 || this.vm.maxPage > 1) {
          ListItem() {
            Row({ space: $r('app.float.space_md') }) {
              Button('‹ 上一页')
                .fontSize($r('app.float.font_size_caption'))
                .fontColor(this.vm.page > 1 ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
                .backgroundColor($r('app.color.card_background'))
                .borderRadius($r('app.float.radius_button'))
                .height(32)
                .enabled(this.vm.page > 1 && !this.vm.loading)
                .onClick((): void => {
                  this.vm.prevPage();
                })
              Text(`${this.vm.page}/${this.vm.maxPage}`)
                .fontSize($r('app.float.font_size_caption'))
                .fontColor($r('app.color.text_secondary'))
              Button('下一页 ›')
                .fontSize($r('app.float.font_size_caption'))
                .fontColor(this.vm.page < this.vm.maxPage ? $r('app.color.text_primary') : $r('app.color.text_tertiary'))
                .backgroundColor($r('app.color.card_background'))
                .borderRadius($r('app.float.radius_button'))
                .height(32)
                .enabled(this.vm.page < this.vm.maxPage && !this.vm.loading)
                .onClick((): void => {
                  this.vm.nextPage();
                })
            }
            .width('100%')
            .justifyContent(FlexAlign.Center)
            .padding({ top: $r('app.float.space_sm'), bottom: $r('app.float.space_xl') })
          }
        }
      }
      .width('100%')
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .divider({
        strokeWidth: 1,
        color: $r('app.color.divider'),
        startMargin: $r('app.float.space_md'),
        endMargin: $r('app.float.space_md')
      })
    }
    .width('100%')
    .height('100%')
  }
}
