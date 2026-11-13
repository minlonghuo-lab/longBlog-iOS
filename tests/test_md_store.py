"""Regression contracts for Stage B: Local Markdown Store + Git Push (No Trilium Dependency)."""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / 'src'


def read_src(filename):
    return (SRC / filename).read_text(encoding='utf-8')


class MdStoreContracts(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.store_h = read_src('LBMdStore.h')
        cls.store_m = read_src('LBMdStore.m')
        cls.lb_h = read_src('LB.h')
        cls.site_m = read_src('LBSite.m')
        cls.editor_m = read_src('LBPostEditor.m')
        cls.content_m = read_src('LBContent.m')
        cls.reader_m = read_src('LBPostReader.m')
        cls.settings_m = read_src('LBSettings.m')

    def test_md_store_declarations_and_methods(self):
        self.assertIn('LBMdStoreDidChange', self.store_h)
        self.assertIn('articlesFolderURL', self.store_h)
        self.assertIn('folderDisplayName', self.store_h)
        self.assertIn('isCustomFolder', self.store_h)
        self.assertIn('setFolderURL:', self.store_h)
        self.assertIn('resetFolderToDefault', self.store_h)
        self.assertIn('listArticles', self.store_h)
        self.assertIn('loadArticle:', self.store_h)
        self.assertIn('saveArticleWithId:', self.store_h)
        self.assertIn('deleteArticleWithId:', self.store_h)
        self.assertIn('generateUniqueNoteID', self.store_h)
        self.assertIn('assetsFolderForNote:', self.store_h)

    def test_security_scoped_bookmark_lifecycle(self):
        self.assertIn('bookmarkDataWithOptions:', self.store_m)
        self.assertIn('URLByResolvingBookmarkData:', self.store_m)
        self.assertIn('startAccessingSecurityScopedResource', self.store_m)
        self.assertIn('stopAccessingSecurityScopedResource', self.store_m)
        self.assertIn('LBArticlesFolderBookmark', self.store_m)

    def test_12_character_base62_note_id_generator(self):
        self.assertIn('generateUniqueNoteID', self.store_m)
        self.assertIn('0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ', self.store_m)
        self.assertIn('arc4random_uniform(62)', self.store_m)
        self.assertIn('buf[12] = \'\\0\'', self.store_m)

    def test_frontmatter_parser_and_serializer(self):
        self.assertIn('parseFrontmatterAndBody:', self.store_m)
        self.assertIn('serializeFrontmatter:', self.store_m)
        self.assertIn('idVal = meta[@"id"]', self.store_m)
        self.assertIn('publish: %@', self.store_m)

    def test_github_contents_api_extensions(self):
        self.assertIn('deleteFile:', self.lb_h)
        self.assertIn('commitChanges:', self.lb_h)
        self.assertIn('articleSnapshot:', self.lb_h)
        self.assertIn('getBlobData:', self.lb_h)
        self.assertIn('@"/git/trees"', self.site_m)
        self.assertIn('@"/git/commits"', self.site_m)
        self.assertIn('@"force":@NO', self.site_m)
        self.assertIn('public/assets/', self.site_m)

    def test_post_editor_saves_drafts_locally_without_network(self):
        save_method = self.editor_m.split('- (void)savePressed {', 1)[1]
        self.assertIn('persistCurrentArticle', save_method)
        self.assertIn('[LBMdStore.shared saveArticleWithId:', self.editor_m)
        self.assertIn('[LBMdStore.shared publishArticle:', self.editor_m)
        self.assertNotIn('putArticleFile:', self.editor_m)
        self.assertNotIn('__block void (^upload', self.editor_m)

    def test_article_list_loads_from_md_store_and_provides_folder_picker(self):
        self.assertIn('[LBMdStore.shared listArticles]', self.content_m)
        self.assertIn('chooseFolder', self.content_m)
        self.assertIn('UTTypeFolder', self.content_m)
        self.assertIn('LBMdStoreDidChange', self.content_m)

    def test_settings_contains_markdown_workspace_card(self):
        self.assertIn('文章工作区 · Markdown 本地目录', self.settings_m)
        self.assertIn('chooseFolderPressed', self.settings_m)
        self.assertIn('resetFolderPressed', self.settings_m)


if __name__ == '__main__':
    unittest.main()
