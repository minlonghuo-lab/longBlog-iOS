"""Source integration contracts, not a claim of UIKit/device runtime execution."""
from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
EDITOR=(ROOT/'src/LBPostEditor.m').read_text()
CONTENT=(ROOT/'src/LBContent.m').read_text().split('#pragma mark - Shuoshuo')[0]
SETTINGS=(ROOT/'src/LBSettings.m').read_text()
class ArticleUI211(unittest.TestCase):
    def test_new_editor_hides_redundant_publication_action(self):
        self.assertNotIn('先存为草稿',EDITOR)
        self.assertNotIn('_publicationActionButton',EDITOR)
        self.assertIn('self.navigationItem.rightBarButtonItem = _saveItem',EDITOR)
        self.assertIn('paperplane.fill',EDITOR)
    def test_preview_preserves_single_source_format_even_for_edited_html_body(self):
        preview=EDITOR.split('- (void)previewPost {')[1].split('#pragma mark - Save')[0]
        self.assertIn('stored[@"bodyFormat"]',preview)
        self.assertIn('_original[@"bodyFormat"]',preview)
        self.assertIn('@"bodyFormat": bodyFormat',preview)
        self.assertIn('@"markdown": markdown',preview)
        for obsolete in ('unchangedBody', 'losslessPreview', 'hasSidecarHtml', 'hasHTMLSidecar', 'stored[@"html"]'):
            self.assertNotIn(obsolete,preview)
        self.assertNotIn('base64EncodedString',preview)
        self.assertNotIn('LBMarkdownToHTML',preview)
        self.assertNotIn('LBHTMLToMarkdown',preview)
    def test_creation_update_and_publication_are_date_only_two_field_cards(self):
        self.assertIn('formatter.dateFormat = @"yyyy-MM-dd"',CONTENT)
        self.assertIn('NSCalendarIdentifierGregorian',CONTENT)
        self.assertNotIn('HH:mm:ss',CONTENT)
        for field in ('createdAt', 'updatedAt', 'publishedAt'):
            self.assertIn('p[@"'+field+'"]',CONTENT)
        self.assertIn('c.metaLabel.text = [NSString stringWithFormat:@"发布：%@    更新：%@", LBArticleTimestamp(pubTs), LBArticleTimestamp(updTs)];',CONTENT)
        self.assertIn('c.metaLabel.text = [NSString stringWithFormat:@"创建：%@    更新：%@", LBArticleTimestamp(creTs), LBArticleTimestamp(updTs)];',CONTENT)
        self.assertIn('pubTs = published > 0 ? published : created',CONTENT)
        self.assertNotIn('LBRelativeTime(',CONTENT)
        self.assertNotIn('LBDateText(',CONTENT)
        self.assertIn('c.metaLabel.numberOfLines = 1',CONTENT)
        self.assertNotIn('HTML保真',CONTENT)
    def test_folder_picker_and_explicit_organizer_use_safe_migration(self):
        self.assertIn('云端强制覆盖',CONTENT)
        self.assertIn('migrateToArticleFoldersWithError:',CONTENT)
        self.assertIn('migrateToArticleFoldersWithError:',SETTINGS)
        self.assertIn('if (![self organizeArticleFolder]) return',CONTENT)
    def test_error_recovery_does_not_repeat_publication(self):
        error=CONTENT.split('- (void)showArticleError:')[1].split('- (void)viewDidAppear:')[0]
        self.assertIn('核验并同步',error)
        self.assertIn('[weakSelf syncArticles:nil]',error)
        self.assertNotIn('publishArticle:',error)
        self.assertIn('error.code != 401 && error.code != 403',error)
    def test_recovery_attachment_collision_never_overwrites_user_file(self):
        restore=EDITOR.split('- (void)restoreAttachmentsFromDraft:')[1].split('- (void)saveDraftToDisk')[0]
        self.assertIn('existing && ![existing isEqual:data]',restore)
        self.assertIn('(!existing && ![data writeToURL:',restore)
if __name__=='__main__': unittest.main()
