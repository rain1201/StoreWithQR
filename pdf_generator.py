#!/usr/bin/env python3
"""
File to QR Code and PDF Converter (Binary Mode) with ZSTD Compression
使用 QR 码存储原始二进制数据，并直接生成包含 QR 码的 PDF 文档，不生成中间图片文件。
支持可选的 ZSTD 压缩功能。
"""

import argparse
import chardet
import hashlib
import io
import json
import math
import os
import pathlib
from PIL import Image
import qrcode
from fpdf import FPDF
import datetime

# 尝试导入 zstd，如果不可用则设置标志
try:
    import zstandard as zstd
    ZSTD_AVAILABLE = True
except ImportError:
    ZSTD_AVAILABLE = False
    print("警告: zstandard 库未安装。如需使用压缩功能，请运行: pip install zstandard")


class QRBackupPDF(FPDF):
    def header(self):
        self.set_y(5)
        # 设定字体
        self.set_font("Arial", "", 12)
        # 页眉内容：左侧标题，右侧日期
        self.cell(0, 2, f"{self.header_title}", border=0, align="L")
        self.set_font("Arial", "", 5)
        self.set_y(9)

        # 添加压缩信息到页眉第二行
        compression_info = f"Size: {self.file_size} bytes | Encoding: {self.file_encoding}"
        if hasattr(self, 'compression_method') and self.compression_method:
            compression_info += f" | Compression: {self.compression_method}"
        compression_info += f" | SHA-1: {self.file_hash[0:8]} | Created: {self.creation_time}"

        self.cell(0, 2, compression_info, border=0, align="L")
        self.set_xy(-40, 5)
        self.set_font("Arial", "", 5)
        self.cell(30, 2, f"{self.header_right_title}", border=0, align="R")
        self.ln(15) # 页眉下方的间距

    def footer(self):
        # 底部向上 15mm
        self.set_y(-10)
        self.set_font("helvetica", "I", 8)
        # 显示页码
        page_no = f"Page {self.page_no()} / {{nb}}"
        self.cell(0, 10, page_no, align="C")


def create_metadata_json(file_name, file_size, file_hash, compression_enabled, compression_level, chunk_size, total_chunks,version=2):
    """
    创建元信息JSON字符串
    """
    # 将压缩算法与压缩等级融合为一个字段
    if compression_enabled and compression_level > 0:
        compression_info = f"ZSTD-{compression_level}"
    else:
        compression_info = "None"
    
    metadata = {
        "filename": file_name,
        "compression": compression_info,  # 融合了压缩算法与压缩等级
        "hash": file_hash,
        "chunk_size": chunk_size,
        "total_chunks": total_chunks,
        "file_size": file_size,
        "version": 2
    }
    return json.dumps(metadata, ensure_ascii=False).encode('utf-8')


def compress_data(data, compression_level=6):
    """
    使用 ZSTD 压缩数据
    """
    if not ZSTD_AVAILABLE:
        raise RuntimeError("ZSTD library is not available. Please install zstandard.")

    cctx = zstd.ZstdCompressor(level=compression_level)
    compressed_data = cctx.compress(data)
    return compressed_data


def decompress_data(compressed_data):
    """
    解压 ZSTD 压缩的数据
    """
    if not ZSTD_AVAILABLE:
        raise RuntimeError("ZSTD library is not available. Please install zstandard.")
    
    dctx = zstd.ZstdDecompressor()
    decompressed_data = dctx.decompress(compressed_data)
    return decompressed_data


def split_data_with_metadata(data, chunk_size, file_name, file_hash, compression_enabled=False, compression_level=-1,version=2,hash=""):
    """
    将二进制数据切片，第一个二维码保存元信息JSON，其余保存文件数据。
    元信息格式: JSON字符串包含文件名、压缩、hash、分块等信息
    数据块格式 (二进制): b'index/chunk_size/total_size|payload'
    """
    # 如果压缩级别大于0，则先压缩整个数据
    if compression_level > 0:
        if not ZSTD_AVAILABLE:
            print("错误: 启用了压缩但 zstandard 库不可用。请安装 zstandard。")
            return []

        original_size = len(data)
        data = compress_data(data, compression_level)
        compressed_size = len(data)
        print(f"压缩前大小: {original_size} 字节")
        print(f"压缩后大小: {compressed_size} 字节")
        print(f"压缩率: {compressed_size/original_size:.2%}")
        compression_used = True
    else:
        compression_used = False

    total_size = len(data)
    num_chunks = math.ceil(total_size / chunk_size)
    
    # 创建元信息JSON作为第一个二维码的内容
    metadata_chunk = create_metadata_json(file_name, len(data), file_hash, compression_enabled, compression_level, chunk_size, num_chunks)
    
    chunks = [metadata_chunk]  # 第一个二维码是元信息
    
    # 从索引1开始添加数据块 (保持与原来相同的格式，但索引从1开始对应实际数据)
    for i in range(num_chunks):
        start_idx = i * chunk_size
        end_idx = min((i + 1) * chunk_size, total_size)
        payload = data[start_idx:end_idx]

        # 构建二进制头部: "索引/块大小/总大小|" (这里索引从1开始，因为0是元信息)
        if(version==1):header = f"{i}/{chunk_size}/{total_size}|".encode('ascii')
        elif(version==2):header = f"{i}/{hash[0:4]}|".encode('ascii')
        # 组合头部和原始二进制数据
        frame = header + payload
        chunks.append(frame)

    return chunks


def generate_qr_image_bytes(chunk, img_size=400):
    """
    生成 QR 码并返回其字节数据，不保存到文件。
    """
    # 初始化 QR 码生成器
    qr = qrcode.QRCode(
        version=None, # 自动计算版本
        error_correction=qrcode.constants.ERROR_CORRECT_L,
        box_size=10,
        border=4,
    )

    # 关键点：直接添加 bytes 数据，qrcode 会自动进入 8-bit 二进制模式
    qr.add_data(chunk)
    qr.make(fit=True)

    img = qr.make_image(fill_color="black", back_color="white").convert('RGB')
    img = img.resize((img_size, img_size), Image.Resampling.NEAREST)

    # 将图像保存到内存中的字节流
    img_byte_arr = io.BytesIO()
    img.save(img_byte_arr, format='PNG')
    img_byte_arr.seek(0)  # 重置指针到开始位置

    return img_byte_arr.getvalue(), qr.version


def detect_encoding(file_data):
    """
    尝试检测文本文件的编码
    """
    # 首先检查是否为纯文本文件
    try:
        # 尝试以ASCII解码，看是否是纯ASCII文本
        file_data.decode('ascii')
        return 'ASCII'
    except UnicodeDecodeError:
        # 如果不是纯ASCII，使用chardet库检测编码
        result = chardet.detect(file_data)
        return result['encoding'] if result['encoding'] else 'unknown'

def gen_tag(chunk, encoding='utf-8'):
    """
    探测数据块内章节标记
    """
    try:
        text = chunk.decode(encoding, errors='ignore')
        # 查找章节标记模式，一行内只有一个整数
        lines = text.splitlines()
        for line in lines:
            line = line.strip()
            if line.isdigit():
                return line
    except:
        pass
    return ""

def create_qr_pdf_from_file(input_file, output_file, chunk_size=2100, img_size=400,
                           paper_size='A4', orientation='P', cols=3, rows=4,
                           qr_size=65.0, margin_top=10.0, margin_side=5.0,
                           compression_enabled=False, compression_level=-1, header_title=None, 
                           header_right_title=None,version=2):
    """
    直接从输入文件创建包含 QR 码的 PDF，不生成中间图片文件。
    支持可选的 ZSTD 压缩功能。
    第一个二维码保存元信息JSON，其余保存文件数据。
    """
    if not os.path.exists(input_file):
        raise FileNotFoundError(f"找不到文件: {input_file}")

    with open(input_file, 'rb') as f:
        file_data = f.read()

    # 计算原始文件哈希值（未压缩）
    original_file_hash = hashlib.sha256(file_data).hexdigest()
    original_file_size = len(file_data)
    file_name = os.path.basename(input_file)

    # 检测文件编码
    if (file_name.endswith(('.txt', '.md', '.py', '.js', '.html', '.css'))):
        file_encoding = detect_encoding(file_data)
    else:
        file_encoding = file_name.split('.')[-1].strip().upper()  # 对于非文本文件，使用扩展名作为编码类型

    # 获取当前时间作为创建时间
    creation_time = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    print(f"原始文件大小: {original_file_size} 字节")
    print(f"文件编码: {file_encoding}")
    print(f"创建时间: {creation_time}")
    print(f"原始文件哈希: {original_file_hash}")
    print(f"PDF设置 - 纸张: {paper_size}{orientation}, 布局: {cols}x{rows}, 二维码大小: {qr_size}mm")

    # 根据是否启用压缩来决定使用哪个哈希值和大小
    if compression_enabled:
        compression_method = f"ZSTD-{compression_level}"
        file_hash = hashlib.sha256(file_data).hexdigest()  # 这里应该使用压缩后的数据的哈希，但为了保持一致性，我们保留原始哈希
        file_size = original_file_size  # 也保留原始大小用于显示
        print(f"启用压缩: ZSTD 级别 {compression_level}")
    else:
        compression_method = None
        file_hash = original_file_hash
        file_size = original_file_size

    chunks = split_data_with_metadata(file_data, chunk_size, file_name, file_hash, compression_enabled, compression_level,version,file_hash)
    print(f"切分为 {len(chunks)} 个数据块 (包括1个元信息块)")

    # 初始化 PDF
    pdf = QRBackupPDF(orientation=orientation, unit="mm", format=paper_size)
    # 尝试添加中文字体，如果不存在则使用默认字体
    try:
        pdf.add_font("Arial", "", "MiSans-Regular.ttf", uni=True)
    except:
        # 如果字体文件不存在，跳过添加字体
        pass
    # 设置文件信息供页眉使用
    if header_title is None:
        header_title = pathlib.Path(file_name).stem
    pdf.header_title = header_title
    pdf.header_right_title = header_right_title
    pdf.file_size = file_size
    pdf.file_encoding = file_encoding
    pdf.file_hash = file_hash
    pdf.creation_time = creation_time
    if compression_enabled:
        pdf.compression_method = compression_method
    pdf.alias_nb_pages() # 用于获取总页数 {nb}
    pdf.set_auto_page_break(auto=True, margin=10)
    pdf.add_page()

    # 计算间距
    page_width = 210
    spacing_x = (page_width - 2 * margin_side - cols * qr_size) / (cols - 1) if cols > 1 else 0
    spacing_y = 2 # 固定垂直间距

    for i, chunk in enumerate(chunks):
        # 检查是否需要换页
        idx_in_page = i % (cols * rows)
        if i > 0 and idx_in_page == 0:
            pdf.add_page()

        # 计算行列坐标
        col = idx_in_page % cols
        row = idx_in_page // cols

        x = margin_side + col * (qr_size + spacing_x)
        y = margin_top + row * (qr_size + spacing_y)

        # 生成 QR 码图像字节数据
        img_bytes, qr_version = generate_qr_image_bytes(chunk, img_size)

        # 将字节数据写入临时文件以便 fpdf 处理
        temp_img_path = f"temp_qr_{i}.png"
        with open(temp_img_path, 'wb') as temp_file:
            temp_file.write(img_bytes)

        # 在 PDF 中绘制二维码
        pdf.image(temp_img_path, x=x, y=y, w=qr_size, h=qr_size)

        # 绘制编号
        pdf.set_xy(x, y + qr_size - 2)
        pdf.set_font("helvetica", "B", 5)
        
        # 特殊处理第一个二维码（元信息）
        if i == 0:
            pdf.cell(qr_size, 5, f"#Metadata Block", align='C')
        else:
            # 对于数据块，解析出原始索引（因为现在索引从1开始对应实际数据）
            if(file_name.endswith(('.txt', '.md', '.py', '.js', '.html', '.css')) and compression_level <= 0):
                tag = gen_tag(chunk)
                pdf.cell(qr_size, 5, f"#Chunk {i-1} Tag:{tag}", align='C')
            else:
                pdf.cell(qr_size, 5, f"#Chunk {i-1}", align='C')

        # 删除临时文件
        os.remove(temp_img_path)

        print(f"已处理第 {i+1}/{len(chunks)} 个 QR 码 (Version {qr_version})")

    pdf.output(output_file)
    print(f"PDF 已成功生成: {output_file}")


def main():
    parser = argparse.ArgumentParser(description='将文件直接转换为包含 QR 码的 PDF 文档 (二进制模式) - 支持 ZSTD 压缩')
    parser.add_argument('input_file', help='要转换的输入文件')
    parser.add_argument('-s', '--chunk-size', type=int, default=2100,
                        help='每个 QR 码存储的字节数 (建议 300-800)')
    parser.add_argument('-o', '--output-pdf', default='qr_backup.pdf',
                        help='PDF 输出文件名')
    parser.add_argument('--size', type=int, default=400,
                        help='生成的 QR 码内部像素尺寸')
    parser.add_argument('--paper', default='A4', choices=['A4', 'A3', 'A5', 'letter'],
                        help='纸张大小 (默认: A4)')
    parser.add_argument('--orientation', default='P', choices=['P', 'L'],
                        help='页面方向，P为纵向，L为横向 (默认: P)')
    parser.add_argument('--cols', type=int, default=3,
                        help='每行二维码数量 (默认: 3)')
    parser.add_argument('--rows', type=int, default=4,
                        help='每列二维码数量 (默认: 4)')
    parser.add_argument('--qr-size', type=float, default=65.0,
                        help='二维码在PDF中的大小(mm) (默认: 65.0)')
    parser.add_argument('--margin-top', type=float, default=12.0,
                        help='上边距(mm) (默认: 10.0)')
    parser.add_argument('--margin-side', type=float, default=5.0,
                        help='左右边距(mm) (默认: 5.0)')
    parser.add_argument('--compression-level', type=int, default=-1,
                        help='ZSTD 压缩级别 (1-22, 启用压缩); -1 表示不启用压缩 (默认: -1)')
    parser.add_argument('--header-title', type=str, default=None,
                        help='页眉第一行标题，如果为空则使用去除后缀的文件名')
    parser.add_argument('--header-right-title', type=str, default="CONFIDENTIAL",
                        help='页眉第一行右侧标题，如果为空则使用去除后缀的文件名')
    parser.add_argument('--version', type=int, default=2,
                        help='标识版本 (1 或 2) (默认: 2)')
    args = parser.parse_args()

    if args.compression_level > 0 and not ZSTD_AVAILABLE:
        print("错误: 启用了压缩但 zstandard 库不可用。请安装 zstandard。")
        return 1

    try:
        create_qr_pdf_from_file(
            args.input_file,
            args.output_pdf,
            chunk_size=args.chunk_size,
            img_size=args.size,
            paper_size=args.paper,
            orientation=args.orientation,
            cols=args.cols,
            rows=args.rows,
            qr_size=args.qr_size,
            margin_top=args.margin_top,
            margin_side=args.margin_side,
            compression_enabled=(args.compression_level > 0),
            compression_level=args.compression_level,
            header_title=args.header_title,
            header_right_title=args.header_right_title,
            version=args.version
        )
        print(f"\n转换完成！PDF 文件已保存为: {args.output_pdf}")

    except Exception as e:
        print(f"错误: {str(e)}")
        return 1
    return 0


if __name__ == "__main__":
    exit(main())