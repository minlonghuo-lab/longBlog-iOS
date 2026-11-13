from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parents[1]
def src(name):return (ROOT/'src'/name).read_text()
def order(rows):return sorted(rows,key=lambda r:(-bool(r['pinned']),-r['displayTs'],-r['id']))
class CountsOrder(unittest.TestCase):
 def test_pinned_stays_above_new_record(self):
  pinned={'id':1,'pinned':True,'displayTs':100};new={'id':2,'pinned':False,'displayTs':200}
  self.assertEqual(order([new,pinned]),[pinned,new])
  self.assertEqual(order([dict(pinned,pinned=False),new])[0],new)
 def test_tie_has_deterministic_id_order(self):
  self.assertEqual([x['id'] for x in order([{'id':n,'pinned':False,'displayTs':10} for n in [1,3,2]])],[3,2,1])
 def test_count_is_full_snapshot_not_first_thirty(self):
  client=src('LBMemosClient.m').split('- (void)allState:')[1].split('- (void)tags:')[0]
  self.assertIn('queryItemWithName:@"creatorId"',client)
  self.assertIn('queryItemWithName:@"rowStatus"',client)
  self.assertNotIn('queryItemWithName:@"limit"',client)
  t=src('LBMemosTimeline.m');self.assertIn('allState:self->_state text:@"" tag:@""',t)
  self.assertIn('allState:other text:@"" tag:@""',t)
  self.assertIn('normal+archived',t)
  self.assertIn('if (_tag.length) match = match',t)
  refresh=t.split('- (void)refresh {')[1].split('- (void)fetch:')[0]
  self.assertIn('_otherStateCount = nil;',refresh)
 def test_write_and_refresh_share_pinned_sort(self):
  t=src('LBMemosTimeline.m');self.assertIn('if (pa != pb) return pa ? NSOrderedAscending',t)
  self.assertIn('_rows = [self ordered:rows]',t)
  self.assertIn('self->_rows = [self ordered:rows]',t)
  self.assertNotIn('[rows insertObject:memo atIndex:0]',t)
 def test_public_dashboard_is_explicit(self):
  self.assertIn('title:@"公开说说"',src('LBDashboard.m'))
  self.assertNotIn('LBMemosClient.shared',src('LBDashboard.m'))
 def test_delete_confirmation_on_normal_and_archive(self):
  t=src('LBMemosTimeline.m');self.assertIn('performsFirstActionWithFullSwipe = NO',t)
  self.assertIn('title:archived ? @"永久删除" : @"删除"',t)
  self.assertIn('fields:@{@"rowStatus":@"ARCHIVED"}',t)
  self.assertIn('deleteArchived:memo',t)
if __name__=='__main__':unittest.main(verbosity=2)
