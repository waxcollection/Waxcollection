"""Preparación de fotografías ligeras para Supabase Storage."""
from io import BytesIO
from PIL import Image, ImageOps


def webp_bytes(source, max_side=800, quality=70):
    with Image.open(source) as original:
        picture = ImageOps.exif_transpose(original)
        # El WEBP final usa RGB o RGBA y conserva transparencia cuando corresponde.
        picture = picture.convert("RGBA" if "A" in picture.getbands() else "RGB")
        picture.thumbnail((max_side, max_side), Image.Resampling.LANCZOS)
        output = BytesIO()
        picture.save(output, format="WEBP", quality=quality, method=6)
        return output.getvalue()
