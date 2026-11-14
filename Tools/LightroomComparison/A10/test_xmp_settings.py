from pathlib import Path
import tempfile
import unittest

from xmp_settings import read_adjustments


class AdjustmentPacketTests(unittest.TestCase):
  def read(self, description):
    with tempfile.TemporaryDirectory() as directory:
      path = Path(directory) / 'test.xmp'
      path.write_text(f'''<rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"
        xmlns:crs="http://ns.adobe.com/camera-raw-settings/1.0/">{description}</rdf:RDF>''')
      return read_adjustments(path)

  def test_preset_attributes_and_tiff_elements_give_the_same_edit(self):
    curve = '''<crs:ToneCurvePV2012Red><rdf:Seq><rdf:li>0, 3</rdf:li>
      <rdf:li>255, 255</rdf:li></rdf:Seq></crs:ToneCurvePV2012Red>'''
    look = '<crs:Look><rdf:Description crs:Highlights2012="100"/></crs:Look>'
    preset = self.read(f'<rdf:Description crs:Highlights2012="-37">{curve}{look}</rdf:Description>')
    tiff = self.read(f'''<rdf:Description><crs:Highlights2012>-37</crs:Highlights2012>
      {curve}</rdf:Description>''')
    self.assertEqual(preset, tiff)
    self.assertEqual(preset, ({'Highlights2012': '-37'}, {'ToneCurvePV2012Red': [[0, 3], [255, 255]]}))

  def test_an_absent_curve_uses_the_host_default_and_an_empty_authored_curve_is_invalid(self):
    self.assertEqual(self.read('<rdf:Description crs:Shadows2012="17"/>'), ({'Shadows2012': '17'}, {}))
    with self.assertRaisesRegex(ValueError, 'Empty ToneCurvePV2012'):
      self.read('<rdf:Description><crs:ToneCurvePV2012><rdf:Seq/></crs:ToneCurvePV2012></rdf:Description>')

  def test_conflicting_values_in_the_same_image_are_rejected(self):
    with self.assertRaisesRegex(ValueError, 'Conflicting Whites2012'):
      self.read('''<rdf:Description crs:Whites2012="10"/>
        <rdf:Description><crs:Whites2012>50</crs:Whites2012></rdf:Description>''')
